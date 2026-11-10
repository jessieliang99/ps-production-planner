# PRESSPILOT (Print Station production planner): office server.
#
# Serves the planner to every computer, tablet and phone in the office and keeps one shared copy of the data,
# so a scan at one station shows up on every other screen within a few seconds.
#
# Start it:   ruby server.rb            (or double-click "Start planner server.command")
# Open it:    http://<this computer's address>:8080   e.g. http://192.168.0.16:8080
#
# Data lives OUTSIDE this folder, in the folder next to it (EFX/PrintStationPlanner-data on the shared drive),
# so customer data never ends up on GitHub. Set PLANNER_DATA to use another folder.
#   state.json        all orders, customers, statuses, settings
#   backups/          an hourly copy of state.json, kept for 30 days
#   files/            delivery photos and signatures
#   outbox/ sent/     emails waiting to go / already sent
#   mail.json         email (SMTP) settings: see SETUP.md. Not created automatically.
#   printlogic.json   PrintLogic mode: read PrintLogic's status emails (printlogic.rb, SETUP.md). Optional.
#
# Needs only the Ruby that ships with macOS (no installs).

require "webrick"
require "json"
require "fileutils"
require "securerandom"
require "base64"
require "net/smtp"
require "time"

APP_DIR  = File.expand_path(__dir__)
DATA_DIR = File.expand_path(ENV["PLANNER_DATA"] || File.join(File.dirname(APP_DIR), "PrintStationPlanner-data"))
PORT     = (ENV["PLANNER_PORT"] || 8080).to_i
# Never start on an empty data folder by accident (for example when the shared drive isn't connected).
unless Dir.exist?(DATA_DIR) || ENV["PLANNER_NEW"] == "1"
  abort "Can't find the planner's data folder:\n  #{DATA_DIR}\nConnect the shared drive (Drive-Jessie) in Finder, then start the server again.\n(To start with a brand-new empty planner instead, run: PLANNER_NEW=1 ruby server.rb)"
end
%w[backups files outbox sent].each { |d| FileUtils.mkdir_p(File.join(DATA_DIR, d)) }

STATE_FILE = File.join(DATA_DIR, "state.json")
MAIL_FILE  = File.join(DATA_DIR, "mail.json")
LOCK = Mutex.new
MAIL_LOCK = Mutex.new

def log(msg)
  $stdout.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}")
  $stdout.flush
rescue StandardError
  nil
end

require_relative "printlogic"

# ---------- shared state ----------
def load_state
  return { "version" => 0, "data" => {} } unless File.exist?(STATE_FILE)
  JSON.parse(File.read(STATE_FILE))
rescue JSON::ParserError
  # A broken file should never lose everything: fall back to the newest backup.
  latest = Dir[File.join(DATA_DIR, "backups", "state-*.json")].max
  latest ? JSON.parse(File.read(latest)) : { "version" => 0, "data" => {} }
end
$state = load_state
$state_json = JSON.generate($state)

def save_state!(json)
  tmp = STATE_FILE + ".tmp"
  File.write(tmp, json)
  File.rename(tmp, STATE_FILE)
  backup = File.join(DATA_DIR, "backups", "state-#{Time.now.strftime('%Y%m%d-%H')}.json")
  FileUtils.cp(STATE_FILE, backup) unless File.exist?(backup)
  cutoff = Time.now - 30 * 86400
  Dir[File.join(DATA_DIR, "backups", "state-*.json")].each { |f| File.delete(f) if File.mtime(f) < cutoff }
end

# ---------- files (delivery photos, signatures) ----------
def safe_path(rel)
  rel = rel.to_s.sub(%r{\A/+}, "")
  return nil if rel.empty? || rel.split("/").any? { |p| p == ".." || p == "." || p.empty? }
  full = File.expand_path(File.join(DATA_DIR, "files", rel))
  full.start_with?(File.join(DATA_DIR, "files") + "/") ? full : nil
end

# ---------- email ----------
def mail_settings
  return nil unless File.exist?(MAIL_FILE)
  s = JSON.parse(File.read(MAIL_FILE))
  s["host"].to_s.empty? || s["user"].to_s.empty? ? nil : s
rescue StandardError
  nil
end

def addrs(s)
  s.to_s.split(/[;,\s]+/).select { |a| a.include?("@") }
end

def build_mime(m, from)
  outer = "ps-#{SecureRandom.hex(8)}"
  alt = "alt-#{SecureRandom.hex(8)}"
  enc = ->(t) { "=?UTF-8?B?#{Base64.strict_encode64(t.to_s)}?=" }
  html = m["html"].to_s
  text = m["text"].to_s
  text = html.gsub(/<br\s*\/?>/i, "\n").gsub(/<[^>]+>/, "").gsub("&nbsp;", " ").gsub("&amp;", "&") if text.empty?
  html = "<div style=\"font-family:Arial,sans-serif;white-space:pre-wrap\">#{text.gsub('&', '&amp;').gsub('<', '&lt;')}</div>" if html.empty?
  h = []
  h << "From: #{m['fromName'] ? "#{enc.(m['fromName'])} <#{from}>" : from}"
  h << "To: #{addrs(m['to']).join(', ')}"
  h << "Cc: #{addrs(m['cc']).join(', ')}" unless addrs(m["cc"]).empty?
  h << "Subject: #{enc.(m['subject'])}"
  h << "Date: #{Time.now.rfc2822}"
  h << "Message-ID: <#{SecureRandom.uuid}@printstation-planner>"
  h << "MIME-Version: 1.0"
  h << "Content-Type: multipart/mixed; boundary=\"#{outer}\""
  body = +""
  body << "--#{outer}\r\nContent-Type: multipart/alternative; boundary=\"#{alt}\"\r\n\r\n"
  body << "--#{alt}\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n#{Base64.encode64(text)}\r\n"
  body << "--#{alt}\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n#{Base64.encode64(html)}\r\n"
  body << "--#{alt}--\r\n"
  (m["attachments"] || []).each do |a|
    name = a["name"].to_s.gsub(/["\r\n]/, "")
    body << "--#{outer}\r\nContent-Type: #{a['type'] || 'application/octet-stream'}; name=\"#{name}\"\r\n"
    body << "Content-Disposition: attachment; filename=\"#{name}\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
    body << Base64.encode64(Base64.decode64(a["data"].to_s)) << "\r\n"
  end
  body << "--#{outer}--\r\n"
  h.join("\r\n") + "\r\n\r\n" + body
end

def deliver(m)
  s = mail_settings or raise "Email isn't set up on the server yet (mail.json)"
  from = s["from"] || s["user"]
  rcpt = (addrs(m["to"]) + addrs(m["cc"]) + addrs(m["bcc"])).uniq
  raise "No recipients" if rcpt.empty?
  smtp = Net::SMTP.new(s["host"], (s["port"] || 587).to_i)
  smtp.enable_starttls if s.fetch("starttls", true)
  smtp.open_timeout = 15
  smtp.read_timeout = 30
  smtp.start("printstation-planner", s["user"], s["password"], :login) do |c|
    c.send_message(build_mime(m, from), s["user"], rcpt)
  end
end

# Try every queued email. Sent ones move to sent/, failures stay with the last error.
def flush_outbox
  MAIL_LOCK.synchronize do
    return unless mail_settings
    Dir[File.join(DATA_DIR, "outbox", "*.json")].sort.each do |f|
      m = JSON.parse(File.read(f))
      begin
        deliver(m)
        m["sentAt"] = Time.now.utc.iso8601
        m.delete("attachments") # keep the sent log small
        File.write(File.join(DATA_DIR, "sent", File.basename(f)), JSON.generate(m))
        File.delete(f)
        log "Email sent: #{m['subject']} -> #{m['to']}"
      rescue StandardError => e
        m["error"] = e.message
        m["tries"] = m["tries"].to_i + 1
        File.write(f, JSON.generate(m))
        log "Email failed: #{m['subject']}: #{e.message}"
      end
    end
  end
end

# ---------- HTTP ----------
class Api < WEBrick::HTTPServlet::AbstractServlet
  def json(res, code, obj)
    res.status = code
    res["Content-Type"] = "application/json"
    res["Cache-Control"] = "no-store"
    res.body = obj.is_a?(String) ? obj : JSON.generate(obj)
  end

  def do_GET(req, res)
    case req.path
    when "/api/ping"
      json(res, 200, { ok: true, version: $state["version"], time: Time.now.utc.iso8601 })
    when "/api/state"
      since = req.query["since"]
      if since && since.to_i == $state["version"]
        res.status = 204
        res["Cache-Control"] = "no-store"
      else
        json(res, 200, $state_json)
      end
    when "/api/mail/status"
      queued = Dir[File.join(DATA_DIR, "outbox", "*.json")].map { |f| JSON.parse(File.read(f)) rescue {} }
      json(res, 200, { configured: !mail_settings.nil?, queued: queued.size,
                       errors: queued.map { |m| { subject: m["subject"], to: m["to"], error: m["error"] } }.select { |m| m[:error] } })
    when "/api/mail/check"
      # Which of these queued emails have actually gone out since.
      ids = req.query["ids"].to_s.split(",").map { |i| i.gsub(/[^\w-]/, "") }.reject(&:empty?).first(200)
      json(res, 200, { sent: ids.select { |i| File.file?(File.join(DATA_DIR, "sent", "#{i}.json")) } })
    when %r{\A/api/printlogic}
      pl_api_get(req, res, self)
    when %r{\A/api/files/(.+)\z}
      p = safe_path(WEBrick::HTTPUtils.unescape($1))
      return json(res, 404, { error: "Not found" }) unless p && File.file?(p)
      res["Content-Type"] = p.end_with?(".png") ? "image/png" : "image/jpeg"
      res["Cache-Control"] = "private, max-age=86400"
      res.body = File.binread(p)
    else
      json(res, 404, { error: "Not found" })
    end
  end

  def do_PUT(req, res)
    case req.path
    when "/api/state"
      body = JSON.parse(req.body || "{}")
      LOCK.synchronize do
        if body["version"].to_i != $state["version"]
          next json(res, 409, $state_json) # someone saved first: the browser re-applies its change and tries again
        end
        fresh = { "version" => $state["version"] + 1, "data" => body["data"] || {}, "savedAt" => Time.now.utc.iso8601, "savedBy" => body["by"].to_s[0, 60] }
        fresh_json = JSON.generate(fresh)
        begin
          save_state!(fresh_json) # write to disk first: if the drive is unreachable, nothing changes and the screen retries
        rescue StandardError => e
          log "Couldn't save (#{e.message}). Is the shared drive connected?"
          next json(res, 503, { error: "The server couldn't save to its data folder. Check the shared drive is connected." })
        end
        $state = fresh
        $state_json = fresh_json
        json(res, 200, { version: $state["version"] })
      end
    when %r{\A/api/printlogic/(sheet/|settings\z)}
      pl_api_put(req, res, self)
    when %r{\A/api/files/(.+)\z}
      p = safe_path(WEBrick::HTTPUtils.unescape($1))
      return json(res, 400, { error: "Bad path" }) unless p
      FileUtils.mkdir_p(File.dirname(p))
      File.binwrite(p, req.body || "")
      json(res, 200, { ok: true })
    else
      json(res, 404, { error: "Not found" })
    end
  rescue JSON::ParserError
    json(res, 400, { error: "Bad JSON" })
  end

  def do_POST(req, res)
    return pl_api_post(req, res, self) if req.path.start_with?("/api/printlogic/")
    return json(res, 404, { error: "Not found" }) unless req.path == "/api/mail"
    # PrintLogic mode: PrintLogic still emails customers, so the planner never does (no doubled emails).
    return json(res, 409, { error: "PrintLogic mode is on: customer emails are sent by PrintLogic, not the planner." }) if pl_on?
    m = JSON.parse(req.body || "{}")
    return json(res, 400, { error: "No recipient" }) if addrs(m["to"]).empty?
    m["queuedAt"] = Time.now.utc.iso8601
    f = File.join(DATA_DIR, "outbox", "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}.json")
    File.write(f, JSON.generate(m))
    id = File.basename(f, ".json")
    unless mail_settings
      return json(res, 202, { status: "queued", id: id, reason: "Email isn't set up on the server yet. It will send once it is." })
    end
    flush_outbox
    if File.exist?(f)
      err = (JSON.parse(File.read(f))["error"] rescue nil)
      json(res, 202, { status: "queued", id: id, reason: "Couldn't send yet (#{err}). The server will keep trying." })
    else
      json(res, 200, { status: "sent", id: id })
    end
  rescue JSON::ParserError
    json(res, 400, { error: "Bad JSON" })
  end
end

class App < WEBrick::HTTPServlet::AbstractServlet
  STATIC = { "/logo.png" => "image/png" }.freeze
  def do_GET(req, res)
    path = req.path == "/" ? "/index.html" : req.path
    if path == "/index.html"
      html = File.read(File.join(APP_DIR, "index.html"))
      res["Content-Type"] = "text/html; charset=utf-8"
      res["Cache-Control"] = "no-cache"
      res.body = html.sub("<head>", "<head>\n<script>window.PLANNER_SERVER = true;</script>")
    elsif STATIC[path] && File.file?(File.join(APP_DIR, path))
      res["Content-Type"] = STATIC[path]
      res["Cache-Control"] = "max-age=3600"
      res.body = File.binread(File.join(APP_DIR, path))
    else
      res.status = 404
      res.body = "Not found"
    end
  end
end

server = WEBrick::HTTPServer.new(
  Port: PORT, BindAddress: "0.0.0.0",
  AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)
server.mount "/api", Api
server.mount "/", App
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

Thread.new { loop { sleep 120; flush_outbox rescue nil } }

ips = Socket.ip_address_list.select { |a| a.ipv4? && !a.ipv4_loopback? }.map(&:ip_address)
log "Print Station planner server running."
log "Data folder: #{DATA_DIR}"
log "Open on this computer:  http://localhost:#{PORT}"
ips.each { |ip| log "Open on tablets/phones:  http://#{ip}:#{PORT}" }
log(mail_settings ? "Email: set up (#{mail_settings['host']})" : "Email: not set up yet; emails are queued in outbox/ (see SETUP.md)")
log(pl_on? ? "PrintLogic mode: on (reading #{pl_boxes.join(', ')})" : pl_mode ? "PrintLogic mode: turned off in Settings" : "PrintLogic mode: off (connect a mailbox in Settings → PrintLogic)")
server.start
