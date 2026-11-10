# PRESSPILOT: setup guide

The planner can run in two ways:

- **PrintLogic mode (for now, while PrintLogic is still in use):** see section 2A. Jobs come from PrintLogic's status emails and Detrack's delivery emails. Orders, job sheets, scanning and customer emails all stay in PrintLogic.
- **On its own (later):** everything below.

Running on its own:

- **Orders and job sheets:** you enter orders and print job sheets in the planner. Every job sheet has its own barcode.
- **Scanning:** scanning that barcode at a station moves the job to the next stage.
- **Office server:** one computer in the office runs the planner. It keeps the only copy of the data and sends the emails.
- **Every other screen** (office computers, tablets at the machines, the driver's phone) just opens a web address.

---

## 1. Start the office server (on the Mac mini)

1. Open the `production-planner` folder.
2. Double-click **Start planner server.command**. A Terminal window opens and shows the addresses to use, for example:

   ```
   Open on this computer:  http://localhost:8080
   Open on tablets/phones:  http://192.168.0.16:8080
   ```

3. **Leave that window open.** Closing it stops the planner on every screen.
4. Keep the Mac awake. In **System Settings → Energy**, turn on **Prevent automatic sleeping when the display is off**.
5. Ask whoever looks after your network to give this Mac a **fixed IP address** (a "DHCP reservation" in the router). Otherwise the tablets' address can change after a restart.

If macOS asks whether Ruby may accept incoming network connections, click **Allow**.

### Where the data is kept

All data is kept on the shared drive at `smb://100.127.35.105/Drive-Jessie/EFX/PrintStationPlanner-data`, next to the `production-planner` folder but outside it, so customer data never ends up on GitHub.

| What | Where |
|---|---|
| Orders, customers, statuses and settings | `state.json` |
| Automatic copies | `backups/`: one copy an hour, kept for 30 days |
| Delivery photos and signatures | `files/` |
| Emails waiting to send, and emails already sent | `outbox/` and `sent/` |

Back up this folder with the rest of the office's backups.

**The shared drive must be connected on the Mac mini.**
- If the drive isn't connected, the server won't start, and it says why.
- If the drive drops out while the server is running, screens show "Can't reach the office server" and keep their changes. They save as soon as the drive is back.

---

### After updating the planner

Restart the office server once (close the Terminal window, then double-click **Start planner server.command** again). The server now reports when queued emails have been sent.

### Each office computer

The first time someone opens the planner on a computer, it asks **Who's using this?** That name goes on everything done there. Tap the name under PRESSPILOT to change it. Scanner tablets, Press screens and the driver's phone are named after their station instead.

### Delivery runs

In **Settings → Delivery runs**, mark each run as **Our van** or **Courier**. Van runs show on the Driver screen (Run 1, Run 2…) and the driver takes a photo at each drop-off. Courier runs need a photo uploaded once the goods are handed over.

## 1A. Signing in on each computer

Everyone has their own PIN (4 to 8 digits). PressPilot opens on a PIN screen, and the computer stays signed in until someone taps **Sign out**. Each person is one of three types:

- **Super admin** (Jessie) can do everything, and is the only one who can manage staff and access in Settings → Staff & PINs.
- **Office & prepress** opens the whole planner. If **Can prioritise** is ticked, they can organise jobs and the production line: each machine's run order, urgent jobs, holds and machine changes. If it isn't ticked, they can look at everything but can't change any of that.
- **Production** shows only one station's jobs. The first time someone signs in on a production computer, they pick the station (a machine, or Finishing). The computer remembers it, so after that staff just type their PIN. **Change station** is on the station screen.

**First-time setup**
1. On the PIN screen, under **First time**, type your name and tap **Sign in with the admin PIN**. This is the old shared PIN.
2. Go to **Settings → Staff & PINs**. Add yourself as **Super admin**, then add everyone else with their role and a PIN.
3. Once you have your own PIN, the old shared admin PIN stops working.

**Managing staff** (Settings → Staff & PINs, super admin only)
- You can add people, change their role, tick or untick **Can prioritise**, give them a **New PIN**, **Revoke access** (or turn it back on later), or **Remove** them.
- Each PIN must be different.
- Revoking access, a new PIN, a removal, or a switch between production and office signs that person out on every computer within a few seconds.
- You can't revoke, remove or change your own role, and there must always be at least one super admin with access.
- After 5 wrong PINs, that computer waits 30 seconds before it will try again.

**What production does at a station** (jobs show in the order the office set):
  - Machines: **Start printing** on the next job, then **Printed · to finishing** (or **Completed · no finishing**) when it's off the press.
  - Finishing: **Start finishing**, then **Completed**. Completed jobs move to Deliveries or Pickups.
  - Production can open a job to read its job sheet, but can't reorder jobs, mark jobs urgent, put them on hold or change the machine.

**Office staff can mark any job completed.** This works for everyone in the office, with or without Can prioritise:
- Tap **✓ Done** on a job's card in Production → Queues.
- Or open the job (search its number) and tap **✓ Mark completed**. **Undo** is in the same place.
- Or use **Completed** in Production → Finishing.

Completed jobs move to Deliveries, or Pickups for pickup jobs.

Factory TVs (`#tv`, `#tv-queues`) and the driver phone (`#drive`) don't need to sign in.

For PrintLogic jobs, these taps are recorded in the planner. When PrintLogic's own status email arrives with a later stage, that takes over.

## 2. Set up the scanner stations (tablets)

> **Scanners are switched off for now.** Production marks jobs on screen instead (see 1A). The scanner setup below is kept for later. To switch scanners back on, set `SCANNERS_OFF` to `false` in index.html.

1. On an office computer, open the planner and click **Admin** to set an admin PIN. Do this once.
2. Go to **Settings → Stations → Set up scanners**. Each row is one station, and each station sets one status:

| Station | What a scan there does |
|---|---|
| Prepress | Plates or files are ready. The job joins its machine's queue. (Digital jobs skip this.) |
| A machine (Digital, HP Indigo, RMGT, SM52, GTO, Wide format, Die cut, Outsourcing) | **First scan:** the job is on press (shows in "Now printing"). **Second scan:** it's printed and goes to post-press. Digital Press can have 2 jobs on at once, other machines 1. Starting a job on a full machine marks the one that's been on longest as printed. |
| Finishing started (optional) | Shows that finishing has begun. The job stays in post-press. |
| Completed at Carlton / Completed at Hurstville | The job is finished at that site. If the customer collects from that site, they are emailed straight away. |

Before any of that, the office clears each job in **Office → Proofs & payments**, with no scanner needed:
- Proof approved, Waiting for artwork, Proof sent, Waiting for stock.
- Payment received, for non-account clients. Admins only.

Once a job is cleared, a Digital job goes straight into the Digital queue and every other job goes to Prepress. In post-press, staff read the job sheet, finish the job, then scan it at Completed or tap **Completed** on the job's card in **Production → Finishing**.

A machine's tablet can also open that machine's **Press screen** (**Settings → Stations**, or **Production → Queues → Press screen ↗**). It shows the run order and takes scans too, so one tablet does both.

3. Click **Copy link** next to a station (also listed in **Settings → Stations**). Open that link on the station's tablet (email it to yourself, or type it in), then use **Share → Add to Home Screen**. The tablet is now that station for good.
4. Pair the Bluetooth barcode scanner with the tablet, the same way as Bluetooth headphones.
   - Most scanners press Enter after each barcode by default. If yours doesn't, scan the "add Enter / CR suffix" code in its manual.
5. Test it: scan a job sheet. A **green** panel means the scan worked. A **red** panel means it didn't, and says why (for example, the job doesn't exist or is on hold).

Phones and tablets can also scan with their camera. Browsers only allow the camera on a secure (https) address, so on the office address (http://…) use the barcode scanner instead.

---

## 2A. PrintLogic mode: read PrintLogic and Detrack emails

While PrintLogic is still in use, the planner reads two mailboxes:

- **production@** for PrintLogic's status emails (created, prepress, printed, completed, pickup, waiting for payment). The job sheet PDF attached to each email is read for the machine, the specification and the special instructions.
- **mail@** for Detrack's emails from notify@detrack.com:
  - Out for delivery and failed deliveries show on the Deliveries screen.
  - A delivered job finishes by itself, with Detrack's proof of delivery PDF attached.

**Connect each mailbox once** (an admin, with the admin PIN):

1. In the planner, open **Settings → PrintLogic → Connect a mailbox…**
2. The planner shows a short code. On any computer or phone, go to **microsoft.com/devicelogin** and type the code.
3. Sign in as **production@printstation.com.au** and accept. (Microsoft asks to allow "Microsoft Graph Command Line Tools" to read mail. That's Microsoft's own app; nothing needs to be set up in Entra.)
4. Then **Connect another mailbox…** and do the same for **mail@printstation.com.au**.

The office server checks both mailboxes every 10 seconds, and open screens refresh every 10 seconds. It only reads: it never sends, moves or deletes email, and it skips Sent Items.

**What changes in the planner while PrintLogic mode is on**

- Only PrintLogic's jobs are shown. Orders entered in the planner (including the demo jobs) are kept but hidden.
- **+ New order** is switched off: orders are entered in PrintLogic.
- **Scanning:**
  - Changes made in PrintLogic show in the planner within about 20 seconds.
  - A planner scan of a PrintLogic job is refused, so nothing is recorded twice.
  - The two planner actions still allowed are **Arrived at Hurstville** and **Collected**.
- **No emails:** the planner sends no customer emails, because PrintLogic already does.
- **Payment holds:** pay-first jobs are held by PrintLogic's **Waiting for Payment** email, and also by the planner's pay-first client list.
- **Admin controls still work:** queue order, urgent, Start printing / Done on the press screens, and delivery runs.
- **If a mailbox can't be read** (for example its sign-in expired or a password changed), every screen shows a red banner. Connect that mailbox again in Settings.

**Turning it off later:** **Settings → PrintLogic → Turn PrintLogic mode off.** The planner then runs on its own orders, job sheets and scanning. Do this once Xero export and email are set up.

**Where it's kept** (in the data folder, never on GitHub):

- `printlogic-auth.json`: the mailbox sign-ins. Anyone with this file can read those mailboxes, so keep the shared drive's access limited.
- `printlogic/`: the jobs read from the emails, plus job sheet and proof-of-delivery PDFs.

If your Microsoft 365 blocks the sign-in ("needs admin approval"), a Microsoft 365 admin approves it once. Alternatively, IT can register an app in Entra with the **Mail.Read** application permission and put its tenantId, clientId, clientSecret and `"mailboxes": ["production@…", "mail@…"]` into `printlogic.json`.

---

## 3. Turn on email (order confirmations and pickup emails)

Until this is done, the planner keeps working and **queues** every email in `EFX/PrintStationPlanner-data/outbox/`. Queued emails send by themselves once email is set up.

While a pickup email is queued, its job stays in **Dispatch → Pickups** marked "Email queued · not sent yet", so nobody thinks the customer has been told. Once the email actually sends, the job moves to "Ready to collect", where staff tap **Collected** when the customer picks it up.

1. **Turn on SMTP sending for mail@** (Microsoft 365 admin, about 5 minutes).
   - Go to **admin.microsoft.com → Users → Active users → mail@printstation.com.au → Mail → Manage email apps**.
   - Tick **Authenticated SMTP** and save.
   - If mail@ uses two-step sign-in, create an **app password** for it.
2. **Create the settings file.** In `EFX/PrintStationPlanner-data`, create a file called `mail.json`:

   ```json
   {
     "host": "smtp.office365.com",
     "port": 587,
     "user": "mail@printstation.com.au",
     "password": "THE-PASSWORD-OR-APP-PASSWORD",
     "from": "mail@printstation.com.au"
   }
   ```

   This file holds a password. It sits in the data folder on the shared drive, outside the `production-planner` folder, so it never goes to GitHub. Anyone who can open that folder can read the password, so keep the drive's access limited.
3. You don't need to restart anything. The server tries the outbox every 2 minutes.

To check email is working, open `http://localhost:8080/api/mail/status`. It should show `"configured": true` and `"queued": 0`.

---

## 4. Open it from home (optional)

The Mac mini is on Tailscale. With Tailscale running on your home computer, open:

**http://100.89.161.116:8080**

That address only works for devices signed in to your Tailscale network.

---

## 5. Optional: start the server automatically

Instead of double-clicking **Start planner server.command** after every restart:

1. Open **System Settings → General → Login Items**.
2. Add **Start planner server.command**.

---

## Opened without the server

If `index.html` is opened directly (from a file, or from GitHub Pages), the planner runs as a **preview**:

- Everything is saved in that one browser only.
- Emails open in your own email app instead of sending.

Use the server address for real work.
