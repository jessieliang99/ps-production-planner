# Production Planner: setup guide

Setup takes about 25 minutes, once. You finish with a web address that any computer, factory screen or phone can open. Everyone signs in with the **production@printstation.com.au** Microsoft account.

The page reads that mailbox straight from Microsoft and keeps shared data (Delivered ticks, RUSH flags and driver runs) in a small file in production's OneDrive, at `PrintStation Planner/planner-state.json`. GitHub only hosts the page. No job data is ever stored there.

---

## Step 1: Create the website address on GitHub (10 min)

1. Go to **github.com** and sign up for a free account. The username becomes part of the address, for example `printstation`.
2. Click **+** (top right), then **New repository**.
   - Repository name: `ps-production-planner`
   - Choose **Public** (free GitHub Pages needs a public repository; the page holds no job data).
   - Click **Create repository**.
3. On the new repository page, click **uploading an existing file**. Drag in `index.html` from the `production-planner` folder, then click **Commit changes**.
4. Go to **Settings**, then **Pages** (left menu).
   - Under *Build and deployment*, set **Source: Deploy from a branch**, **Branch: main**, folder **/ (root)**, and click **Save**.
5. After about a minute, the page shows your address:
   **`https://jessieliang99.github.io/ps-production-planner/`**
   Copy it. You need it in step 2.

## Step 2: Let Microsoft sign in to the page (10 min, admin)

1. Go to **entra.microsoft.com** and sign in with your admin account.
2. Open **Identity → Applications → App registrations → New registration**.
   - Name: `Production Planner`
   - Supported account types: **Accounts in this organizational directory only**
   - Redirect URI: choose **Single-page application (SPA)** and paste the address from step 1. It must match exactly, including the `/` at the end.
   - Click **Register**.
3. On the app's **Overview** page, copy these two values:
   - **Application (client) ID**
   - **Directory (tenant) ID**
4. Open **API permissions → Add a permission → Microsoft Graph → Delegated permissions**, and tick:
   - `Mail.Read`
   - `Files.ReadWrite`
   - `User.Read` (usually already there)
   - `Mail.Send` (sends order confirmations with the PDF attached)

   Click **Add permissions**, then **Grant admin consent for Print Station** and confirm.
5. Order confirmations go out from **mail@printstation.com.au**. In the Microsoft 365 admin centre, open that mailbox → **Mailbox permissions → Send as** and add **production@printstation.com.au**. Without this, Microsoft refuses to send and the planner shows the error.

## Step 3: Put the two IDs into the page (2 min)

1. In GitHub, open the repository and click `index.html`, then the **pencil** (Edit) icon.
2. Near the top, find these lines:
   ```js
   clientId: "PASTE-APPLICATION-CLIENT-ID-HERE",
   tenantId: "PASTE-DIRECTORY-TENANT-ID-HERE",
   ```
   Replace the text inside the quotes with the two IDs from step 2.3.
3. While you're there, check the delivery runs:
   ```js
   defaultRuns: ["PS Delivery", "Go Logistics", "StarTrack / Australia Post"],
   ```
   You can also change these later from **Settings** on the page.
4. Click **Commit changes**. The site updates within about a minute.

## Step 4: Open it on each screen

| Where | Address | Notes |
|---|---|---|
| Office computers | `https://jessieliang99.github.io/ps-production-planner/` | Bookmark it. |
| Factory floor TV | `https://jessieliang99.github.io/ps-production-planner/#tv` | Large type, clock, refreshes itself every 2 minutes. Set the TV's browser to open this on startup. |
| Drivers' phones | Same address | Opens on **Deliveries** on a phone. In Safari or Chrome, use *Share → Add to Home Screen* to get an app icon. |

On each device, click **Sign in with Microsoft** and sign in as **production@printstation.com.au**. The device stays signed in, so this is usually needed only every few months.

Then on any one device:
1. Click **Settings**, set **Clear old completed jobs** to today's date, and click **Mark as delivered**. This clears jobs that went out before you started using the planner.
2. Ask each person to put their name in **Settings → Your name on this device**, so ticks show who did them.

---

## How the board decides where a job goes

| Column | PrintLogic email that puts it there |
|---|---|
| Created | "… Created by: …" |
| Queued by machine | "… - Prepress". The machine comes from the attached jobsheet ("Print Station Production **HP Indigo** JOB NO.") |
| Printed · finishing | "HP Printed", "RMGT Printed" |
| Scanned complete | "… - Completed" or "… is completed at Carlton" |
| Pickup | "Your order is ready to be picked up at …", or completed with "pick up"/"collect" in the delivery notes |
| Delivered / collected | Someone clicked **Delivered** or **Collected** |

**RUSH:** set automatically when the description or delivery notes say URGENT, ASAP or RUSH. Anyone can add or remove it from the job's panel. RUSH jobs sit at the top of every column.

**Run sheets:** on the **Deliveries** tab, choose a run for each job, then click **Print run sheet**. It prints a table with the address, contact and a signature column.

## If something goes wrong

- **"This page isn't set up yet"**: the IDs in step 3 haven't been filled in, or the change hasn't gone live yet. Wait a minute and reload.
- **Sign-in error mentioning a redirect URI**: the address in step 2.2 doesn't exactly match the page address. Check `https`, the username, and the `/` at the end.
- **"Microsoft refused access" (401/403)**: admin consent wasn't granted (step 2.4), or someone signed in with a different account.
- **Machines show "Not set"**: PrintLogic left the machine blank on that jobsheet, or Microsoft Search hasn't indexed a brand-new email yet. It usually fills in on the next refresh.
- **Ticks not showing on other screens**: they sync every 30 seconds. Press **Refresh** to sync straight away.

## About the shared login

Everyone uses one account, so anyone with that password can read the whole production mailbox. Keep the password with the admin, and sign devices in for staff rather than handing the password out. If the account uses multi-factor sign-in, the code goes to whoever holds the authenticator, which is another reason for an admin to sign each device in once.

---

## Admin mode, holds, urgent jobs and proof of delivery

**Admin PIN.** The first time anyone tries an admin action (reordering a machine, marking a job urgent, putting a job on hold), the planner asks them to create the admin PIN. Share it only with admins. Each device stays unlocked for 12 hours; use **Admin → Lock now** on shared screens. **Change PIN** locks every other device straight away. The PIN stops accidental changes; it is not strong security, because the page code is public.

**Holds.** In a job's panel an admin can choose *Waiting for proof approval* or *Waiting for stock / paper*, with an optional note. *Waiting for payment* is set automatically when PrintLogic sends its "Waiting for Payment" email; an admin clears it with **Payment received · release**. Held jobs leave the run order and sit under **On hold** on their machine.

**Urgent jobs.** When an urgent job isn't #1 on its machine, Machine queues asks an admin: **Move to #1** or **Keep my order**. If you keep your order, it won't ask again unless the job is marked urgent again.

**Proof of delivery.** **Delivered** and **Collected** open a screen for a photo (the phone camera opens), a signature and the receiver's name. Photos and signatures are saved to production's OneDrive in `PrintStation Planner/Proof of delivery/<job number>/` and show in the job's panel. **Save without proof** is there for exceptions and is recorded as such.
