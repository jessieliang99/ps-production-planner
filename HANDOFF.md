# Handover notes: PRESSPILOT (Print Station production planner)

Read this first when you pick the project up on another computer.

## Where to work
Work from the shared drive: smb://100.127.35.105/Drive-Jessie/EFX. On a Mac it is mounted at `/Volumes/Drive-Jessie/EFX`.

Older copies on the Desktop and the Synology NAS are out of date, so don't edit those.

The customer CSVs sit in `EFX`, outside `production-planner`. Never upload them to GitHub.

## What this is
`index.html` holds the whole app in one file: the HTML, the CSS and the JavaScript.

**Goal (changed 2026-11-06):** a standalone app that replaces PrintLogic completely. PrintLogic is no longer used: no PrintLogic emails, job sheets or statuses. Everything starts from orders entered here, the job sheets printed here, and their barcodes being scanned at each station. It covers:
- orders and job sheets with barcodes,
- scanning and statuses,
- order confirmations,
- the export of invoices to Xero.

It also replaces Detrack, which handles deliveries.

**How it runs:** `server.rb` is the office server. It uses only the Ruby that comes with macOS, and runs on the office Mac mini on port 8080. It does four things:
- serves the page,
- keeps one shared state file at `EFX/PrintStationPlanner-data/state.json`, on the shared drive next to `production-planner`, with versioned saves: a stale save gets 409 and the browser re-applies its change,
- stores delivery photos,
- sends email through SMTP. Emails are queued in `outbox/` until `mail.json` is set up.

**PrintLogic mode (added 2026-11-09, the trial stage while PrintLogic is still in use):** `printlogic.rb`, loaded by `server.rb`, reads mailboxes through Microsoft Graph.
- **Sign-in:** a device-code sign-in with Microsoft's public client `14d82eec-…`, scope Mail.Read. Refresh tokens are kept in `printlogic-auth.json`, one per mailbox. Mailboxes are connected from Settings → PrintLogic.
- **Mail check:** every 60 seconds, the server reads every connected mailbox and skips Sent Items. It reads:
  - PrintLogic status emails from mail@: the subject is classified the way the old browser version did, prices are stripped, and the job sheet PDF is saved;
  - Detrack emails from notify@detrack.com: the `LABEL : value` fields give the status and the D.O. number gives the job; the POD PDF is saved.
- **Storage and API:** jobs are stored in `PrintStationPlanner-data/printlogic/jobs.json`. Endpoints:
  - `GET /api/printlogic?since=rev` for the jobs;
  - `/api/printlogic/todo` and `PUT /api/printlogic/sheet/<no>`, through which the browser reads job sheets with pdf.js (`sheetLines` + `parseSheet`);
  - `/api/printlogic/settings|connect|cancel|disconnect` for Settings.
- **In the browser:** PrintLogic jobs get `job.pl = true`.
  - While the mode is on, planner orders are hidden and customer email is blocked, both in the browser and with a 409 from the server.
  - Planner scans of PrintLogic jobs are refused, except Arrived at Hurstville and Collected.
  - A "Delivered" from Detrack finishes the job.

The server injects `window.PLANNER_SERVER = true` into the page. Opened any other way, the page is a preview that keeps its data in localStorage (`pp-preview-state`). Microsoft sign-in and OneDrive were removed. See `SETUP.md`.

## Run it locally
```bash
cd production-planner
ruby server.rb
```
Then open http://localhost:8080. Tablets use the Mac's address, which the server prints when it starts.

To use separate test data, set `PLANNER_DATA=/some/folder` and `PLANNER_PORT=8091` when starting the server. The customer CSV and the `PrintStationPlanner-data` folder (on the shared drive) are private: never commit them.

## Business rules to keep

**Payment and holds**
- Customers who are not account clients pay before production. Payment is confirmed by hand by an admin.
- Jobs show as "Not ready" until the customer's type (Account or Pay first) has been set.
- Production screens show job details only. Never show payment, client checks, hold reasons or dollar amounts there.
- Client checks appear only in Sales.

**Admin controls**
- Admins unlock with a shared PIN.
- Only admins can reorder machine queues, mark jobs urgent, put jobs on hold and change machines.
- Machine dropdowns appear only inside the job window, never on cards.

**Job numbers**
- Planner order numbers start at 500001.
- In each order, the first Good takes the order number (500003), and further Goods add letters (500003a, 500003b and so on).
- Every job line gets its own job sheet and a unique Code 128 barcode.
- Each line's type is either Good or Service.

**Statuses and scanners**
- Statuses keep PrintLogic's names (`PL_STATUS`), because staff know them.
- Each named scanner station is tied to one status. A tablet is locked to a station with the link `#scan/<id>`.
- The scanners are Bluetooth or USB barcode scanners paired to tablets, phones or PCs. They type like a keyboard and press Enter. The scan screen also catches scans when its box doesn't have focus.
- Every scan shows a large green or red result.
- "Completed Email - Hurstville/Carlton Pick up" sends the pickup email in the old wording. On the Pickups page, the "Email customer" button does the same.
- The Carlton pickup address is 70 Planthurst Road, Carlton NSW 2218 ("our Carlton Factory").

**Production flow (agreed 2026-11-06)**
- **Order entered.** Non-account clients wait for payment (an admin confirms it). Every job waits for proof approval unless the order ticks "Artwork already approved".
- **Approvals happen in Office → Proofs & payments**, by tapping buttons, because the office has no scanners. These are statuses:
  - `ProofApproved`, which also sets `proofOk`,
  - `WaitingArtwork`, `WaitingApproval`, `WaitingStock`,
  - `Ready`.
- **Routing once cleared.** A Digital job goes straight to the Digital queue. Every other job goes to the Prepress queue.
- **Prepress scan:** the job joins its machine's queue.
- **Machine scan = printed:** the job moves to post-press. Post-press has no scanner. Only Die cut and Foil are flagged (by `finishingOf()`); staff read the job sheet for all other finishing.
- **Completed at Carlton/Hurstville scan:** the job goes to dispatch or pickup. If the customer collects from that same site, the pickup email goes out automatically, so there is no separate email scan. A Carlton job collected at Hurstville is emailed when it is scanned at Completed at Hurstville.
- **Job window, top to bottom:** header (what, who, due) → status card (progress, current state, one next action) → job sheet → customer & delivery → order (office only) → More actions and History (both folded away). Production hides money, client and order details.
- **Approve all in order:** one tap approves every waiting job in the order. Cloned orders tick "Artwork already approved" by default.
- **Holds block scans.** Any hold blocks production scans, which show a red "Not ready".

**Order form**
- Save & print job sheets, then send the order confirmation, as a PDF from mail@.
- There is no Attention field, receiver phone, due time, proof or quote number.

**Deliveries**
- Deliveries need a photo stamped with the time, date and GPS. Only PS Delivery runs take photos.
- The driver view (`#drive`) shows only the address, the customer, the instructions and the photo button.
- Office staff drag stops to set the run order.

**Other screens and rules**
- The Press screen for each machine is at `#press/<machine>`.
- Phone numbers use the standard Australian format with spaces: 0412 345 678, 02 9580 0360.
- The Xerox Versant counts as Digital Press. Digital Press, HP R2000 Latex and Perfect Bound EVA jobs skip Prepress: Digital jobs wait in the Digital queue for the proof; Latex and EVA jobs go straight into their own machine's queue, ready to print. "Offset", "Offset Print" and "Offset Printed" are one Offset machine. Queue order: Prepress, Digital Press, HP Indigo, RMGT 790, then the rest.

## Still to do

**Waiting on the owner**
- A list of account clients, so customer types can be set and held jobs clear.
- Whether a Service should ever get its own job sheet.
- Whether to keep the red "Unpaid" note on Pickups.

**Not started**
- Turn on email: SMTP AUTH for mail@ plus `mail.json` (see `SETUP.md`).
- A paper test with the office's real Bluetooth scanners on the tablets.
- Camera scanning on tablets needs https, for example through `tailscale serve`.
- Later: move the state from one JSON file to a database once order history grows large.
- Later: staff logins. Today anyone on the office network or Tailscale can open it.
- Separate runs for each driver, if there is more than one van.

## Working rules
- Never commit customer data: no CSVs and no PrintLogic exports.
- Check the JavaScript still parses after each edit.
- Test in the browser at localhost:8080.
