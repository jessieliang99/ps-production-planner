# encoding: utf-8
# PrintLogic mode: the office server reads email (Microsoft Graph) and keeps a list of jobs for the planner:
#   - PrintLogic's status emails (production@): created, prepress, printed, completed, pickup, payment…
#   - Detrack's delivery emails (mail@, from notify@detrack.com): out for delivery, delivered, failed
#
# Connect each mailbox in the planner: Settings → PrintLogic → Connect a mailbox. Someone signs in once as that
# mailbox (Microsoft shows a short code to type at microsoft.com/devicelogin), and the server keeps reading from
# then on. Every connected mailbox is read for both kinds of email. Sent Items are skipped.
#
# Stored in the data folder:
#   printlogic.json         settings: on/off, who PrintLogic and Detrack send from, how far back to read
#   printlogic-auth.json    the mailbox sign-ins (refresh tokens). Private: anyone with it can read those mailboxes.
#   printlogic/jobs.json    every job seen in the emails, with its statuses (no prices: amounts are stripped)
#   printlogic/sheets/      the newest job sheet PDF from each job's emails
#   printlogic/pod/         Detrack's proof-of-delivery PDF for each delivered job
#
# For IT: instead of signing in, printlogic.json can hold an Entra app's tenantId, clientId, clientSecret and
# "mailboxes": ["production@…", "mail@…"] (application permission Mail.Read). That's used first if it's there.

require "net/http"
require "uri"
require "json"
require "fileutils"
require "time"

PL_CONFIG = File.join(DATA_DIR, "printlogic.json")
PL_AUTH   = File.join(DATA_DIR, "printlogic-auth.json")
# Microsoft's own public sign-in app for Graph ("Microsoft Graph Command Line Tools"), so nothing has to be
# registered in Entra. printlogic.json can name another one as "publicClientId".
PL_PUBLIC_CLIENT = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
PL_SCOPE  = "offline_access Mail.Read User.Read"
PL_LOGIN  = "https://login.microsoftonline.com/organizations/oauth2/v2.0"
PL_DIR    = File.join(DATA_DIR, "printlogic")
PL_JOBS   = File.join(PL_DIR, "jobs.json")
PL_SHEETS = File.join(PL_DIR, "sheets")
PL_PODS   = File.join(PL_DIR, "pod")
PL_LOCK   = Mutex.new
PL_AUTH_LOCK = Mutex.new
PL_GRAPH  = "https://graph.microsoft.com/v1.0"

$pl_status = { "lastPoll" => nil, "error" => nil }
$pl_claims = {}  # jobNo => time a screen took it to read the job sheet
$pl_connect = nil # the sign-in in progress: user code, link, state
$pl_tokens = {}  # mailbox => { value:, until: }
$pl_sent = {}    # mailbox => Sent Items folder id

def pl_read_json(f)
  File.exist?(f) ? JSON.parse(File.read(f)) : {}
rescue StandardError
  {}
end

def pl_write_json(f, h)
  File.write(f + ".tmp", JSON.pretty_generate(h))
  File.rename(f + ".tmp", f)
end

# Settings with their defaults. PrintLogic's emails come from mail@ (the old planner's setting).
def pl_config
  { "enabled" => true, "sender" => "mail@printstation.com.au", "detrackSender" => "notify@detrack.com", "sinceDays" => 45 }.merge(pl_read_json(PL_CONFIG))
end

def pl_app?(c)
  %w[tenantId clientId clientSecret].all? { |k| !c[k].to_s.strip.empty? && !c[k].to_s.include?("PASTE") } &&
    !(Array(c["mailboxes"]) + [c["mailbox"]]).compact.reject(&:empty?).empty?
end

# Signed-in mailboxes: { "production@…" => { refreshToken, clientId, connectedAt, connectedBy } }
def pl_auths
  a = pl_read_json(PL_AUTH)
  a = { "mailboxes" => { (a["account"] || "mailbox") => a } } if a["refreshToken"] # the first version kept just one
  (a["mailboxes"] || {}).reject { |_, v| v["refreshToken"].to_s.empty? }
end

def pl_save_auth(account, entry)
  PL_AUTH_LOCK.synchronize do
    all = pl_auths
    entry.nil? ? all.delete(account) : all[account] = entry
    all.empty? ? (File.delete(PL_AUTH) if File.exist?(PL_AUTH)) : pl_write_json(PL_AUTH, { "mailboxes" => all })
  end
end

def pl_boxes(c = pl_config)
  pl_app?(c) ? (Array(c["mailboxes"]) + [c["mailbox"]]).compact.map(&:to_s).reject(&:empty?).uniq : pl_auths.keys
end

def pl_mode(c = pl_config)
  return :app if pl_app?(c)
  return :user unless pl_auths.empty?
  nil
end

def pl_on?
  c = pl_config
  c["enabled"] != false && !pl_mode(c).nil?
end

def pl_load
  FileUtils.mkdir_p(PL_SHEETS)
  FileUtils.mkdir_p(PL_PODS)
  j = File.exist?(PL_JOBS) ? JSON.parse(File.read(PL_JOBS)) : {}
  { "rev" => 0, "cursors" => {}, "jobs" => {} }.merge(j)
rescue JSON::ParserError
  { "rev" => 0, "cursors" => {}, "jobs" => {} }
end
$pl = pl_load

def pl_save!
  tmp = PL_JOBS + ".tmp"
  File.write(tmp, JSON.generate($pl))
  File.rename(tmp, PL_JOBS)
end

def pl_touch(job)
  $pl["rev"] = $pl["rev"].to_i + 1
  job["rev"] = $pl["rev"]
end

def pl_job(job_no)
  $pl["jobs"][job_no] ||= { "jobNo" => job_no, "events" => [], "company" => "", "contact" => "", "phone" => "", "email" => "",
                            "description" => "", "po" => "", "delivery" => "", "due" => "", "orderDate" => "" }
end

def pl_seen?(job, imid)
  job["events"].any? { |e| e["imid"] == imid }
end

# ---------- reading PrintLogic's emails (same rules the planner used in the browser) ----------
NO_MONEY = /\$\s?[\d,]+(\.\d{2})?\s*(\([^)]*\))?/

def pl_classify(subject)
  s = subject.to_s
  if (m = s.match(/ready to be picked up at (?:our )?(.+)$/i))
    return { "kind" => "pickup", "label" => "Ready for pickup", "site" => m[1].split(",").last.to_s.sub(/\s*Factory\s*$/i, "").strip }
  end
  if (m = s.match(/is completed at\s+([A-Za-z ]+?)\s*-/i))
    return { "kind" => "completed", "label" => "Scanned complete", "site" => m[1].strip }
  end
  return { "kind" => "completed", "label" => "Scanned complete" } if s =~ /-\s*Completed\s*$/i
  return { "kind" => "awaitpay", "label" => "Waiting for payment", "by" => s[/Payment\s*-\s*(.+)$/i, 1].to_s.strip } if s =~ /Waiting for Payment/i
  # Payment confirmed: "Attn: … Paid - Please proceed", "Complete Own Payment - …", "Completed & Paid"
  return { "kind" => "closed", "label" => "Completed & Paid" } if s =~ /Completed\s*&\s*(Paid|Invoiced)/i
  return { "kind" => "paid", "label" => "Payment confirmed" } if s =~ /\bPaid\s*-\s*Please proceed|Own Payment/i
  return { "kind" => "invoiced", "label" => "Invoiced", "by" => s[/By\s+(.+)$/i, 1].to_s.strip } if s =~ /Invoiced/i
  # Not ready yet: waiting for approval, artwork or stock, artwork being done, on hold
  if (m = s.match(/(Waiting\s+(?:for\s+)?\w+|Doing Artwork|On Hold)\s*(?:-\s*(.+))?$/i))
    return { "kind" => "waiting", "label" => m[1].strip.sub(/\Aon hold\z/i, "On hold"), "by" => m[2].to_s.strip }
  end
  return { "kind" => "closed", "label" => "Cancelled", "cancelled" => true } if s =~ /\bCancell?ed\b/i
  return { "kind" => "created", "label" => "Job created", "by" => s[/Created by:\s*(.+)$/i, 1].to_s.strip } if s =~ /Created by:/i
  if (m = s.match(/-\s*(.*?Printed.*)$/i))
    l = m[1].sub(/\s*\(.*\)\s*$/, "").strip
    return { "kind" => "printed", "label" => l.empty? ? "Printed" : l }
  end
  return { "kind" => "prepress", "label" => "Prepress" } if s =~ /Prepress/i
  l = s.sub(/^\s*\d{6}\s*-?\s*/, "").gsub(NO_MONEY, "").sub(/\s*-{1,2}\s*-{0,2}\s*$/, "").strip
  { "kind" => "other", "label" => l.empty? ? "Update" : l }
end

def pl_job_no(subject)
  subject.to_s[/(?:^|\D)(\d{6})(?!\d)/, 1]
end

PL_LABELS = ["Order Date:", "Company:", "Email:", "Contact:", "Job:", "Client PO:", "Description:", "Delivery address:", "Delivery Instruction:", "Date Due:", "Order #:"].freeze

def pl_fields(text)
  t = text.to_s.tr(" ", " ").delete("\r")
  hits = PL_LABELS.map { |l| (i = t.index(l)) ? [l, i] : nil }.compact.sort_by { |_, i| i }
  f = {}
  hits.each_with_index do |(l, i), k|
    stop = k + 1 < hits.size ? hits[k + 1][1] : t.size
    v = t[(i + l.size)...stop].to_s
    v = v.sub(/_{4,}.*\z/m, "").sub(/Print Station Production.*\z/m, "").sub(/(\.\.\.|…)\s*\z/, "")
    v = v.gsub(/[ \t]+/, " ").gsub(/\s*\n\s*/, "\n").strip
    f[l.delete(":")] = v
  end
  if f["Contact"]
    ph = f["Contact"][/Ph:\s*(.*)$/, 1]
    f["Phone"] = ph.strip if ph
    f["Contact"] = f["Contact"].sub(/\s*Ph:.*$/, "").strip
  end
  f
end

def pl_better(a, b)
  a = a.to_s
  b = b.to_s
  return b if a.empty?
  return a if b.empty?
  b.size > a.size ? b : a
end

# Add one PrintLogic email to its job. Returns the job, or nil if it isn't a job email (or was seen already).
def pl_add_email(m)
  subject = m["subject"].to_s
  job_no = pl_job_no(subject)
  return nil unless job_no
  imid = (m["internetMessageId"] || m["id"]).to_s
  job = pl_job(job_no)
  return nil if pl_seen?(job, imid)
  c = pl_classify(subject)
  c["by"] = c["by"].to_s.gsub(NO_MONEY, "").strip if c["by"]
  job["events"] << c.merge("at" => m["receivedDateTime"], "link" => m["webLink"].to_s, "att" => !!m["hasAttachments"], "mid" => m["id"].to_s, "imid" => imid)
  text = m["text"].to_s
  f = pl_fields(text)
  if c["kind"] == "pickup"
    job["description"] = f["Description"].to_s if job["description"].empty?
    job["delivery"] = f["Delivery Instruction"].to_s if job["delivery"].empty?
    if job["company"].empty? && (cm = text.match(/_{4,}\s*\n+\s*([^\n]+)\n/))
      job["company"] = cm[1].strip
    end
  else
    { "company" => "Company", "contact" => "Contact", "phone" => "Phone", "email" => "Email", "description" => "Description",
      "po" => "Client PO", "delivery" => "Delivery address" }.each { |k, l| job[k] = pl_better(job[k], f[l]) }
    job["orderDate"] = f["Order Date"].to_s if job["orderDate"].to_s.empty?
    due = f["Date Due"].to_s[/\d{4}-\d{2}-\d{2}/]
    job["due"] = due if due && due != "0000-00-00"
  end
  if job["company"].empty? && c["kind"] == "created" && (cm = subject.match(/^\s*\d{6}\s*-\s*(.+?)\s*--/))
    job["company"] = cm[1].gsub(NO_MONEY, "").strip
  end
  job["description"] = job["description"].gsub(NO_MONEY, "")
  pl_touch(job)
  job
end

# ---------- Detrack's delivery emails ----------
# Detrack writes "LABEL : value" pairs (STATUS, REASON, DETRACK NO., DELIVER TO, RECEIVED BY…). The job number is
# the Detrack D.O. number, which also appears in the subject and the POD file name ("detrack-pod-… 313116.pdf").
PL_DT_LABELS = ["DELIVERY STATUS", "JOB STATUS", "STATUS", "REASON", "DETRACK NO.", "DETRACK NO", "JOB TYPE", "PHONE", "RUN NO.", "RUN NO",
                "DELIVER TO", "DELIVERY ADDRESS", "ADDRESS", "INSTRUCTIONS", "D.O. NO.", "D.O. NO", "DO NO.", "DO NO", "ORDER NO.", "ORDER NO",
                "JOB NO.", "JOB NO", "TRACKING NO.", "TRACKING NO", "RECEIVED BY", "RECIPIENT", "RECEIVER", "SIGNED BY", "DRIVER", "ASSIGN TO",
                "VEHICLE", "DATE", "TIME", "COMPLETED AT", "DELIVERED AT", "NAME", "COMPANY", "NOTE", "NOTES", "REMARKS"].freeze
PL_DT_RE = /(?<![A-Za-z.])(#{PL_DT_LABELS.map { |l| Regexp.escape(l) }.join('|')})\s*:\s?/i
def pl_detrack_fields(text)
  t = text.to_s.tr(" ", " ").delete("\r")
  marks = []
  t.scan(PL_DT_RE) { marks << [$1.strip, $~.begin(0), $~.end(0)] }
  f = {}
  marks.each_with_index do |(label, _, stop), i|
    v = t[stop...(i + 1 < marks.size ? marks[i + 1][1] : t.size)].to_s.gsub(/\s+/, " ").strip
    v = "" if v =~ /\AN\/?A\z/i
    f[label.upcase.gsub(/\s+/, " ").sub(/(NO)\z/, '\1.')] ||= v
  end
  f
end

PL_DT_FAILED = /\b(fail(ed|ure)?|not delivered|undelivered|unsuccessful|partial(ly)? delivered|returned)\b/i
PL_DT_OUT = /\b(out for delivery|on the way|en route|dispatched|in transit|in progress|assigned|heading)\b/i
PL_DT_DONE = /\b(delivered|completed|proof of delivery)\b/i
# The STATUS field decides when there is one; otherwise the subject, then the start of the email.
def pl_detrack_status(subject, text, f)
  st = [f["STATUS"], f["DELIVERY STATUS"], f["JOB STATUS"]].compact.join(" ")
  unless st.strip.empty?
    return "failed" if st =~ PL_DT_FAILED
    return "delivered" if st =~ PL_DT_DONE
    return "out" if st =~ PL_DT_OUT
  end
  [subject.to_s, text.to_s[0, 600]].each do |s|
    return "failed" if s =~ PL_DT_FAILED
    return "out" if s =~ PL_DT_OUT
    return "delivered" if s =~ PL_DT_DONE || s =~ /\bPOD\b/
  end
  "update"
end

def pl_detrack_job_no(subject, text, f)
  cands = [f["D.O. NO."], f["DO NO."], f["ORDER NO."], f["JOB NO."], f["TRACKING NO."], subject, text]
  cands.each do |v|
    n = v.to_s[/(?<![\d\/.-])([35]\d{5})(?![\d\/.-])/, 1]
    return n if n
  end
  nil
end

def pl_add_detrack(m)
  subject = m["subject"].to_s
  text = m["text"].to_s
  f = pl_detrack_fields(text)
  job_no = pl_detrack_job_no(subject, text, f)
  return nil unless job_no
  imid = (m["internetMessageId"] || m["id"]).to_s
  job = pl_job(job_no)
  return nil if pl_seen?(job, imid)
  status = pl_detrack_status(subject, text, f)
  reason = f["REASON"].to_s
  by = [f["RECEIVED BY"], f["RECIPIENT"], f["RECEIVER"], f["SIGNED BY"]].compact.find { |v| !v.empty? }.to_s
  label = { "delivered" => "Delivered (Detrack)", "failed" => "Delivery failed (Detrack)", "out" => "Out for delivery (Detrack)" }[status] || "Detrack update"
  label += ": #{reason}" if status == "failed" && !reason.empty?
  job["events"] << { "kind" => "detrack", "status" => status, "label" => label, "reason" => reason, "receivedBy" => by,
                     "detrackNo" => f["DETRACK NO."].to_s, "driver" => (f["DRIVER"] || f["ASSIGN TO"]).to_s, "at" => m["receivedDateTime"],
                     "link" => m["webLink"].to_s, "att" => !!m["hasAttachments"], "mid" => m["id"].to_s, "imid" => imid }
  job["company"] = (f["DELIVER TO"] || f["NAME"] || f["COMPANY"]).to_s[0, 80] if job["company"].empty?
  pl_touch(job)
  job
end

# ---------- Microsoft Graph ----------
def pl_http(uri, req)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |h| h.request(req) }
end

def pl_post_form(url, form)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri)
  req.set_form_data(form)
  res = pl_http(uri, req)
  [res, (JSON.parse(res.body) rescue {})]
end

def pl_ms_error(j, res)
  d = j["error_description"].to_s.sub(/\s*Trace ID:.*/m, "").strip
  d.empty? ? "Microsoft said #{res.code}" : d
end

def pl_token(c, box)
  key = pl_app?(c) ? "app" : box
  t = $pl_tokens[key]
  return t[:value] if t && t[:until] > Time.now
  if pl_app?(c)
    res, j = pl_post_form("https://login.microsoftonline.com/#{c['tenantId']}/oauth2/v2.0/token",
                          "client_id" => c["clientId"], "client_secret" => c["clientSecret"], "grant_type" => "client_credentials", "scope" => "https://graph.microsoft.com/.default")
    raise "Microsoft sign-in failed: #{pl_ms_error(j, res)}" unless res.code == "200"
  else
    a = pl_auths[box] or raise "#{box} isn't connected. Connect it in Settings → PrintLogic."
    res, j = pl_post_form("#{PL_LOGIN}/token", "client_id" => a["clientId"] || PL_PUBLIC_CLIENT, "grant_type" => "refresh_token",
                                                 "refresh_token" => a["refreshToken"], "scope" => PL_SCOPE)
    unless res.code == "200"
      raise "The sign-in for #{box} has expired or was revoked. Connect it again in Settings → PrintLogic." if j["error"] == "invalid_grant"
      raise "Microsoft sign-in failed for #{box}: #{pl_ms_error(j, res)}"
    end
    # Microsoft hands out a new refresh token each time: keep the newest.
    pl_save_auth(box, a.merge("refreshToken" => j["refresh_token"], "refreshedAt" => Time.now.utc.iso8601)) if j["refresh_token"]
  end
  $pl_tokens[key] = { value: j["access_token"], until: Time.now + j["expires_in"].to_i - 120 }
  j["access_token"]
end

# Where the mail is: the signed-in account's own mailbox, or the named mailbox for an Entra app.
def pl_base(c, box)
  pl_app?(c) ? "/users/#{URI.encode_www_form_component(box)}" : "/me"
end

def pl_get(c, box, url, raw: false)
  uri = URI(url.start_with?("http") ? url : PL_GRAPH + url)
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{pl_token(c, box)}"
  req["Prefer"] = 'outlook.body-content-type="text"'
  res = pl_http(uri, req)
  if res.code != "200"
    msg = (JSON.parse(res.body)["error"]["message"] rescue res.code)
    raise "Microsoft said (#{box}): #{msg}"
  end
  raw ? res.body : JSON.parse(res.body)
end

# An email's PDF attachment matching want, saved to dir/<job>.pdf. With any_pdf, another PDF will do.
def pl_fetch_pdf(c, box, mid, want, dir, job_no, any_pdf: false)
  base = "#{pl_base(c, box)}/messages/#{URI.encode_www_form_component(mid)}/attachments"
  list = pl_get(c, box, "#{base}?$select=id,name,contentType,size")["value"] || []
  pdfs = list.select { |a| a["contentType"].to_s =~ /pdf/i || a["name"].to_s =~ /\.pdf\z/i }
  att = pdfs.find { |a| a["name"].to_s =~ want } || (any_pdf ? pdfs.first : nil)
  return nil unless att
  bytes = pl_get(c, box, "#{base}/#{URI.encode_www_form_component(att['id'])}/$value", raw: true)
  # Write then rename, so a screen never reads a half-written PDF.
  f = File.join(dir, "#{job_no}.pdf")
  File.binwrite(f + ".tmp", bytes)
  File.rename(f + ".tmp", f)
  att["name"].to_s
end

# ---------- connecting a mailbox (Microsoft's device sign-in: a short code typed at microsoft.com/devicelogin) ----------
def pl_connect_start(by)
  client = pl_config["publicClientId"] || PL_PUBLIC_CLIENT
  res, j = pl_post_form("#{PL_LOGIN}/devicecode", "client_id" => client, "scope" => PL_SCOPE)
  raise "Microsoft didn't start the sign-in: #{pl_ms_error(j, res)}" unless res.code == "200"
  conn = { "state" => "waiting", "userCode" => j["user_code"], "url" => j["verification_uri"],
           "expiresAt" => (Time.now + j["expires_in"].to_i).utc.iso8601, "by" => by.to_s[0, 60] }
  $pl_connect = conn
  Thread.new do
    interval = [j["interval"].to_i, 5].max
    deadline = Time.now + j["expires_in"].to_i
    while Time.now < deadline && $pl_connect.equal?(conn)
      sleep interval
      r, t = pl_post_form("#{PL_LOGIN}/token", "client_id" => client, "grant_type" => "urn:ietf:params:oauth:grant-type:device_code", "device_code" => j["device_code"]) rescue [nil, {}]
      next if r.nil?
      if r.code == "200"
        account = begin
          uri = URI("#{PL_GRAPH}/me?$select=mail,userPrincipalName")
          q = Net::HTTP::Get.new(uri)
          q["Authorization"] = "Bearer #{t['access_token']}"
          me = JSON.parse(pl_http(uri, q).body)
          (me["mail"] || me["userPrincipalName"]).to_s.downcase
        rescue StandardError
          ""
        end
        account = "mailbox #{pl_auths.size + 1}" if account.empty?
        pl_save_auth(account, { "refreshToken" => t["refresh_token"], "clientId" => client, "connectedAt" => Time.now.utc.iso8601, "connectedBy" => conn["by"] })
        $pl_tokens.delete(account)
        conn["state"] = "connected"
        conn["account"] = account
        log "PrintLogic: mailbox connected (#{account})"
        Thread.new { pl_poll }
        break
      end
      case t["error"]
      when "authorization_pending" then next
      when "slow_down" then interval += 5
      else
        conn["state"] = "failed"
        conn["error"] = t["error"] == "expired_token" ? "The code ran out. Start again." : pl_ms_error(t, r)
        break
      end
    end
    if conn["state"] == "waiting" && $pl_connect.equal?(conn)
      conn["state"] = "failed"
      conn["error"] = "The code ran out. Start again."
    end
  end
  conn
end

def pl_settings_view
  c = pl_config
  auths = pl_auths
  boxes = pl_boxes(c).map do |b|
    a = auths[b] || {}
    { account: b, connectedAt: a["connectedAt"], connectedBy: a["connectedBy"], lastRead: ($pl_status["boxes"] || {})[b] }
  end
  { enabled: c["enabled"] != false, on: pl_on?, mode: pl_mode(c), sender: c["sender"], detrackSender: c["detrackSender"], sinceDays: c["sinceDays"],
    mailboxes: boxes, lastPoll: $pl_status["lastPoll"], error: $pl_status["error"], jobs: $pl["jobs"].size,
    connect: $pl_connect && $pl_connect.reject { |k, _| k == "by" } }
end

# ---------- the mailbox check (every 10 seconds) ----------
PL_POLL = Mutex.new
def pl_poll
  return unless PL_POLL.try_lock # one mailbox check at a time
  begin
    pl_poll_once
  ensure
    PL_POLL.unlock
  end
end

def pl_read_box(c, box)
  sender = c["sender"].to_s.downcase.strip
  detrack = c["detrackSender"].to_s.downcase.strip
  $pl["cursors"] ||= {}
  since = $pl["cursors"][box] || (box == pl_boxes(c).first && $pl["cursor"]) || (Time.now.utc - c["sinceDays"].to_i * 86400).iso8601
  sent = ($pl_sent[box] ||= (pl_get(c, box, "#{pl_base(c, box)}/mailFolders/sentitems?$select=id")["id"] rescue ""))
  q = URI.encode_www_form("$filter" => "receivedDateTime ge #{since}", "$orderby" => "receivedDateTime asc",
                          "$select" => "id,subject,receivedDateTime,body,webLink,internetMessageId,from,hasAttachments,parentFolderId", "$top" => "50")
  url = "#{pl_base(c, box)}/messages?#{q}"
  added = 0
  30.times do
    page = pl_get(c, box, url)
    (page["value"] || []).each do |m|
      PL_LOCK.synchronize { $pl["cursors"][box] = m["receivedDateTime"] if m["receivedDateTime"].to_s > $pl["cursors"][box].to_s }
      next if !sent.to_s.empty? && m["parentFolderId"] == sent # our own sent mail, never a status
      from = (m.dig("from", "emailAddress", "address") || "").downcase
      msg = m.merge("text" => m.dig("body", "content").to_s[0, 20_000])
      # Which senders look like delivery notices (to find Detrack's real address). Addresses and names only.
      fname = m.dig("from", "emailAddress", "name").to_s
      if "#{from} #{fname} #{m['subject']}" =~ /detrack|delivery|delivered|\bPOD\b/i
        PL_LOCK.synchronize { k = "#{fname} <#{from}>"[0, 120]; ($pl["deliverySenders"] ||= {})[k] = ($pl["deliverySenders"][k] || 0) + 1 }
      end
      if !detrack.empty? && (from == detrack || from.end_with?("@detrack.com"))
        job = PL_LOCK.synchronize do
          $pl["detrackSeen"] = $pl["detrackSeen"].to_i + 1
          j = pl_add_detrack(msg)
          # Keep a few that couldn't be matched to a job, to see why (no prices in Detrack emails).
          if j.nil? && !pl_detrack_job_no(msg["subject"], msg["text"], pl_detrack_fields(msg["text"]))
            ($pl["detrackMisses"] ||= []).unshift({ "at" => m["receivedDateTime"], "from" => from, "subject" => m["subject"].to_s[0, 200], "text" => msg["text"].to_s[0, 1500] })
            $pl["detrackMisses"] = $pl["detrackMisses"].first(15)
          end
          j
        end
        next unless job
        added += 1
        ev = job["events"].last
        if ev["status"] == "delivered" && m["hasAttachments"]
          begin
            name = pl_fetch_pdf(c, box, m["id"], /pod/i, PL_PODS, job["jobNo"], any_pdf: true)
            PL_LOCK.synchronize { job["pod"] = { "name" => name, "at" => m["receivedDateTime"] }; pl_touch(job) } if name
          rescue StandardError => e
            log "PrintLogic: couldn't get the Detrack POD for #{job['jobNo']}: #{e.message}"
          end
        end
      elsif sender.empty? || from == sender
        job = PL_LOCK.synchronize { pl_add_email(msg) }
        next unless job
        added += 1
        next unless m["hasAttachments"] && (job["sheet"].nil? || job["sheet"]["at"].to_s <= m["receivedDateTime"].to_s)
        begin
          name = pl_fetch_pdf(c, box, m["id"], /job\s*sheet/i, PL_SHEETS, job["jobNo"])
          PL_LOCK.synchronize { job["sheet"] = { "name" => name, "at" => m["receivedDateTime"], "fields" => nil }; pl_touch(job) } if name
        rescue StandardError => e
          log "PrintLogic: couldn't get the job sheet for #{job['jobNo']}: #{e.message}"
        end
      end
    end
    url = page["@odata.nextLink"]
    break unless url
  end
  added
end

def pl_poll_once
  c = pl_config
  return unless pl_on?
  added = 0
  errors = []
  read = {}
  pl_boxes(c).each do |box|
    begin
      added += pl_read_box(c, box)
      read[box] = Time.now.utc.iso8601
    rescue StandardError => e
      errors << e.message
      log "PrintLogic: #{e.message}"
    end
  end
  PL_LOCK.synchronize do
    # Forget jobs with no news for 120 days.
    cutoff = (Time.now.utc - 120 * 86400).iso8601
    $pl["jobs"].delete_if do |no, j|
      old = j["events"].map { |e| e["at"].to_s }.max.to_s < cutoff
      if old
        [PL_SHEETS, PL_PODS].each { |d| f = File.join(d, "#{no}.pdf"); File.delete(f) if File.exist?(f) }
      end
      old
    end
    pl_save!
  end
  pl_refetch_sheets(c)
  log "PrintLogic: #{added} new email#{added == 1 ? '' : 's'}" if added > 0
  $pl_status = { "lastPoll" => Time.now.utc.iso8601, "error" => errors.empty? ? nil : errors.join(" "), "boxes" => ($pl_status["boxes"] || {}).merge(read) }
rescue StandardError => e
  $pl_status = { "lastPoll" => Time.now.utc.iso8601, "error" => e.message, "boxes" => $pl_status["boxes"] }
  log "PrintLogic: #{e.message}"
end

# Jobs whose job sheet went missing (an order confirmation PDF was taken by mistake before 2026-11-09):
# look through their emails again, newest first, for the "Jobsheet" PDF. A few per check.
def pl_refetch_sheets(c)
  todo = PL_LOCK.synchronize { $pl["jobs"].values.select { |j| j["refetch"] }.first(40) }
  todo.each do |job|
    found = nil
    job["events"].select { |e| e["att"] && !e["mid"].to_s.empty? && e["kind"] != "detrack" }.sort_by { |e| e["at"].to_s }.reverse.each do |e|
      pl_boxes(c).each do |box|
        found = (pl_fetch_pdf(c, box, e["mid"], /job\s*sheet/i, PL_SHEETS, job["jobNo"]) rescue nil)
        if found
          PL_LOCK.synchronize { job["sheet"] = { "name" => found, "at" => e["at"], "fields" => nil } }
          break
        end
      end
      break if found
    end
    PL_LOCK.synchronize { job.delete("refetch"); pl_touch(job) }
  end
  PL_LOCK.synchronize { pl_save! } unless todo.empty?
end

# One-off tidy-ups of data read by earlier versions.
def pl_migrate!
  changed = false
  $pl["jobs"].each_value do |job|
    # Statuses the first version didn't know (waiting, on hold, paid) were kept as plain updates.
    job["events"].each do |e|
      next unless e["kind"] == "other"
      n = pl_classify(e["label"])
      next if n["kind"] == "other"
      e.merge!(n)
      changed = true
    end
    # An order confirmation PDF isn't a job sheet: find the real one again.
    if job["sheet"] && job["sheet"]["name"].to_s !~ /job\s*sheet/i
      f = File.join(PL_SHEETS, "#{job['jobNo']}.pdf")
      File.delete(f) if File.exist?(f)
      job["sheet"] = nil
      job["refetch"] = true
      changed = true
    end
    # The job sheet reader improved: read every sheet again.
    # v3: the Description box also ends at "Sample to Match" / "Printed by", and wrapped lines are joined.
    # Keep the old details on screen (marked stale) until a screen has read the sheet again.
    # Checked per sheet, so a sheet read by a screen still running an older version is read again too.
    f = job["sheet"] && job["sheet"]["fields"]
    if f && f["ok"] != false && f["parser"].to_i < 4 && !f["stale"]
      f["stale"] = true
      changed = true
    end
    # Multi-sheet PDFs: special instructions ran on into the next sheet. Read them again with the fixed reader.
    if job["sheet"] && job["sheet"]["fields"] && job["sheet"]["fields"]["special"].to_s =~ /JOB NO\./i
      job["sheet"]["fields"] = nil
      changed = true
    end
    # Sheets that couldn't be opened (read while still being saved): try again.
    if job["sheet"] && job["sheet"]["fields"] && job["sheet"]["fields"]["error"]
      job["sheet"]["fields"] = nil
      changed = true
    end
    pl_touch(job) if changed
  end
  $pl["parser"] = 3
  pl_save! if changed
end
pl_migrate!

# ---------- API for the planner screens ----------
def pl_send_pdf(res, api, f)
  return api.json(res, 404, { error: "Not found" }) unless File.file?(f)
  res["Content-Type"] = "application/pdf"
  res["Cache-Control"] = "no-cache"
  res.body = File.binread(f)
end

def pl_api_get(req, res, api)
  case req.path
  when "/api/printlogic"
    since = req.query["since"].to_i
    return api.json(res, 200, { on: false }) unless pl_on?
    if since > 0 && since == $pl["rev"].to_i
      res.status = 204
      res["Cache-Control"] = "no-store"
      return
    end
    jobs = PL_LOCK.synchronize { $pl["jobs"].select { |_, j| since.zero? || j["rev"].to_i > since } }
    api.json(res, 200, { on: true, rev: $pl["rev"].to_i, full: since.zero?, lastPoll: $pl_status["lastPoll"], error: $pl_status["error"], jobs: jobs })
  when "/api/printlogic/settings"
    api.json(res, 200, pl_settings_view)
  when "/api/printlogic/todo"
    # One job sheet no screen has read yet. Claimed for 2 minutes so screens don't all read the same one.
    now = Time.now
    no = PL_LOCK.synchronize do
      # Newest sheets first, so live jobs are read before old ones. "stale" = read before, but due a re-read.
      pick = $pl["jobs"].values
        .select { |j| j["sheet"] && (j["sheet"]["fields"].nil? || j["sheet"]["fields"]["stale"]) && (!$pl_claims[j["jobNo"]] || $pl_claims[j["jobNo"]] < now - 120) }
        .max_by { |j| j["sheet"]["at"].to_s }
      $pl_claims[pick["jobNo"]] = now if pick
      pick && pick["jobNo"]
    end
    # Sheets read by an older reader since the last start: mark them for a re-read too.
    PL_LOCK.synchronize { $pl["jobs"].each_value { |j| f = j["sheet"] && j["sheet"]["fields"]; f["stale"] = true if f && f["ok"] != false && f["parser"].to_i < 4 && !f["stale"] } } unless no
    no ? api.json(res, 200, { jobNo: no, at: $pl["jobs"][no]["sheet"]["at"] }) : (res.status = 204)
  when %r{\A/api/printlogic/sheet/(\d{6})\.pdf\z}
    pl_send_pdf(res, api, File.join(PL_SHEETS, "#{$1}.pdf"))
  when %r{\A/api/printlogic/pod/(\d{6})\.pdf\z}
    pl_send_pdf(res, api, File.join(PL_PODS, "#{$1}.pdf"))
  else
    api.json(res, 404, { error: "Not found" })
  end
end

# Settings → PrintLogic: connect or disconnect mailboxes. (The admin PIN is checked on the screen.)
def pl_api_post(req, res, api)
  body = JSON.parse(req.body.to_s.empty? ? "{}" : req.body)
  case req.path
  when "/api/printlogic/connect"
    begin
      pl_connect_start(body["by"])
      api.json(res, 200, pl_settings_view)
    rescue StandardError => e
      api.json(res, 502, { error: e.message })
    end
  when "/api/printlogic/cancel"
    $pl_connect = nil # stops the waiting sign-in; connected mailboxes stay
    api.json(res, 200, pl_settings_view)
  when "/api/printlogic/disconnect"
    box = body["account"].to_s
    pl_save_auth(box, nil)
    $pl_tokens.delete(box)
    $pl_connect = nil
    log "PrintLogic: #{box} disconnected by #{body['by']}"
    api.json(res, 200, pl_settings_view)
  else
    api.json(res, 404, { error: "Not found" })
  end
end

# Settings, and a screen reporting what it read on a job sheet (machine, job name, specification, special instructions).
def pl_api_put(req, res, api)
  if req.path == "/api/printlogic/settings"
    body = JSON.parse(req.body || "{}")
    c = pl_read_json(PL_CONFIG)
    c["enabled"] = !!body["enabled"] if body.key?("enabled")
    %w[sender detrackSender].each { |k| c[k] = body[k].to_s.strip.downcase if body.key?(k) }
    c["sinceDays"] = [[body["sinceDays"].to_i, 1].max, 120].min if body.key?("sinceDays")
    pl_write_json(PL_CONFIG, c)
    log "PrintLogic: settings changed by #{body['by']} (#{c.reject { |k, _| k.to_s =~ /secret/i }.to_json})"
    Thread.new { pl_poll } if pl_on?
    return api.json(res, 200, pl_settings_view)
  end
  m = req.path.match(%r{\A/api/printlogic/sheet/(\d{6})\z})
  return api.json(res, 404, { error: "Not found" }) unless m
  body = JSON.parse(req.body || "{}")
  PL_LOCK.synchronize do
    job = $pl["jobs"][m[1]]
    return api.json(res, 404, { error: "No such job" }) unless job && job["sheet"]
    return api.json(res, 409, { error: "A newer job sheet arrived" }) if body["at"].to_s != job["sheet"]["at"].to_s
    f = body["fields"].is_a?(Hash) ? body["fields"] : { "ok" => false }
    # No prices in production: strip amounts from every text field, the description lines included.
    f.each { |k, v| f[k] = v.gsub(NO_MONEY, "") if v.is_a?(String) }
    f["sections"] = f["sections"].map { |sec| sec.is_a?(Array) ? sec.map { |l| l.is_a?(String) ? l.gsub(NO_MONEY, "").gsub(/\(\s*price included[^)]*\)/i, "").squeeze(" ").strip : l } : sec } if f["sections"].is_a?(Array)
    if f["error"] && job["sheet"]["tries"].to_i < 3
      job["sheet"]["tries"] = job["sheet"]["tries"].to_i + 1 # couldn't open it: let a screen try again later
      $pl_claims[m[1]] = Time.now
    else
      job["sheet"]["fields"] = f
    end
    pl_touch(job)
    pl_save!
  end
  api.json(res, 200, { ok: true })
end

Thread.new do
  sleep 3
  loop do
    pl_poll
    # Every 10 seconds (user's call). Each check is one small request per mailbox, well inside Microsoft's limits.
    sleep 10
  end
end
