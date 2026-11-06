# Handover notes: Print Station production planner

Read this first when you pick the project up on another computer.

## What this is
`index.html` holds the whole app in one file: the HTML, the CSS and the JavaScript.

**Goal:** replace PrintLogic, which today handles:
- orders and job sheets with barcodes,
- scanning and statuses,
- order confirmations,
- the export of invoices to Xero.

It also replaces Detrack, which handles deliveries.

**Mode:** it is in preview mode. All data is saved in the browser's localStorage, under the key `pp-preview-state`. Live mode will use Microsoft sign-in, with the shared data saved in a JSON file on OneDrive. `SETUP.md` covers that setup.

## Run it locally
```bash
cd production-planner
ruby -run -e httpd . -p 8080 -b 127.0.0.1
```
Then open http://localhost:8080.

Browser data is saved separately for each computer. To get customers into a fresh browser, use the planner's customer import. The customer CSV is private: never commit it to this repo.

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
- Statuses copy PrintLogic's list (`PL_STATUS`).
- Scanners work like PrintLogic's: each named scanner is tied to one status. A device can be locked to a scanner with the link `#scan/<id>`.
- "Completed Email - Hurstville/Carlton Pick up" sends the pickup email in PrintLogic's wording.
- The Carlton pickup address is 70 Planthurst Road, Carlton NSW 2218 ("our Carlton Factory").

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
- The Xerox Versant counts as Digital Press.

## Still to do

**Waiting on the owner**
- A list of account clients, so customer types can be set and held jobs clear.
- Whether a Service should ever get its own job sheet.
- Whether to keep the red "Unpaid" note on Pickups.

**Not started**
- Microsoft sign-in and live mode (see `SETUP.md`).
- A real database, with Supabase (Sydney) recommended over the AFT server.
- A paper test with a real USB barcode scanner.
- Separate runs for each driver, if there is more than one van.

## Working rules
- Never commit customer data: no CSVs and no PrintLogic exports.
- Check the JavaScript still parses after each edit.
- Test in the browser at localhost:8080.
