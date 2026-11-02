# DMS Barcode Implementation

## Workflow map

| Workflow | Interface | Barcode behavior | Inventory behavior |
|---|---|---|---|
| Product identification | Existing React scanner, inventory page, and Salesforce scanner | Resolve `Product2.Barcode__c` to an active product | Read-only |
| Primary dispatch | Salesforce `DMS_Dispatch__c` record page | Record scans against dispatch lines and show dispatched, scanned, and remaining quantities | Scan only updates `DMS_Dispatch_Line__c.Scanned_Quantity__c`; company stock remains controlled by the existing dispatch-confirmation workflow |
| Secondary dispatch | React Fulfillment | Count matching products against the selected invoice's remaining lines | Dispatch creation and confirmation remain on existing fulfillment APIs |
| GRN | React Inventory / GRN form | Count matching products from the selected dispatched shipment; received and damaged quantities remain editable | Existing GRN processing adds accepted quantities only |
| Returns | React Invoicing / Returns | Count matching products from the selected invoice | Existing return approval, inspection, and completion logic controls stock |
| Inventory lookup | React Inventory | Search or scan a barcode and display authorized distributor stock | Read-only |

## Salesforce objects and fields

- `Product2.Barcode__c` is the canonical text barcode field. It is already unique, optional, and capped at 50 characters.
- `Inventory__c` remains keyed by product and warehouse. Distributor REST responses are scoped to the signed-in distributor's `Distributor Warehouse` records.
- `DMS_Dispatch__c` and `DMS_Dispatch_Line__c` represent dispatches and their products.
- `DMS_Dispatch_Line__c.Scanned_Quantity__c` stores primary-dispatch verification progress. It is not a stock quantity.
- GRNs remain linked to a dispatched shipment. GRN lines require the matching primary order line; their `DMS_Dispatch_Line__c` lookup is optional. When omitted, the server resolves the unique matching line on that shipment and uses it to enforce shipped-quantity limits without storing the dispatch-line lookup on the GRN line.
- GRN receipt lines continue to use `Goods_Receipt_Line_Item__c`; return lines continue to use `Return_Item__c`.

The current product master has one barcode per product. There is no separate unit/carton barcode or packaging-barcode mapping. Scanning is therefore accepted only when the product unit, dispatch-line unit, and unit conversion are compatible; otherwise the user must enter and verify the quantity manually.

## Implemented code and APIs

### Salesforce

- `DMSBarcodeScannerController.lookupBarcode` — existing read-only product and visible-stock lookup.
- `DMSBarcodeScannerController.getDispatchLines` — loads only the current, accessible company Primary Dispatch lines and scan progress.
- `DMSBarcodeScannerController.scanDispatchBarcode` — validates active barcode/product, current Primary Dispatch, product-line membership, unit compatibility, and remaining quantity; records one scan on the line. It does not update `Inventory__c`.
- `DMSFulfillmentResource.validateDispatchBarcode` — validates each React secondary-dispatch scan against the authenticated distributor's posted invoice, invoice line, remaining quantity, and unit.
- `DMSDistributorInventoryResource.validateReceiptBarcode` — validates each React GRN scan against the authenticated distributor's dispatched primary shipment, dispatch line, remaining quantity, and unit.
- `DMSInvoiceReturnResource.validateReturnBarcode` — validates each React return scan against the authenticated distributor's posted invoice, invoice line, delivered quantity, existing return requests, and unit.
- `DMSCompanyPrimaryWorkflowResource.confirmPrimaryDispatch` — existing authorized company-stock deduction path; barcode scanning does not replace or call it.
- `DMSDistributorInventoryResource.recordGoodsReceipt` — GRN processing validates each primary order line against the selected shipment and quantity limits, with or without a GRN-line dispatch-line lookup, then adds accepted quantities through its existing inventory transaction path.
- `DMSFulfillmentResource` — existing distributor dispatch workflow validates invoice membership and dispatch quantities.
- `DMSInvoiceReturnResource.createReturn` / return completion — existing invoice-line, delivery, approval, inspection, and stock rules remain authoritative.
- `DMS_Dispatch_Line__c.Scanned_Quantity__c` is the only new scan-progress field.
- `DMS_Company_Inventory_Access` grants the company scanner's Apex access, read access to required transaction/product data, and edit access only to the scan-progress field on dispatch lines.

### Lightning Web Component

The existing `dmsBarcodeScanner` LWC is extended with a `dispatch` mode. It retains its existing product/inventory lookup mode and can be added to `DMS_Dispatch__c` record pages. In dispatch mode, it displays dispatch number/status and the product, barcode, dispatched, scanned, and remaining quantities.

The USB scanner uses the dedicated barcode input and Enter suffix. Camera scanning starts only after user action, prefers the rear-facing camera, stops after a successful detection, and stops its media tracks when closed or disconnected. Each camera detection records at most one scan; additional physical units can be scanned individually.

### React

- The existing reusable `src/components/barcode/BarcodeScanner.jsx` continues to provide USB/manual entry and camera lookup.
- `src/pages/Fulfillment.jsx` uses the scanner to count products against the selected invoice and calls `validateDispatchBarcode` before incrementing a count; dispatch creation still revalidates invoice membership and quantities.
- `src/pages/Inventory.jsx` uses the scanner for GRN line verification and calls `validateReceiptBarcode` before incrementing a count; its GRN save API remains authoritative for accepted quantities. The stock table now includes barcode in display and text search.
- `src/pages/Invoicing.jsx` provides barcode verification when drafting a return and calls `validateReturnBarcode` before incrementing a count; the existing return API remains authoritative for approval and inventory processing.
- `src/services/authApi.js` continues to use the existing Salesforce REST API and DMS session; no new credentials or backend service were added.

## Setup

1. Deploy the Salesforce source and assign the `DMS_Company_Inventory_Access` permission set only to authorized company operators.
2. In Lightning App Builder, edit the `DMS_Dispatch__c` record page and add the existing **DMS Barcode Scanner** component.
3. Set **Scanner mode** to `dispatch`, save, activate, and assign the page to the intended app/profile/record type.
4. Ensure the user has record access to the relevant dispatch and permission to use a USB scanner or camera in their browser.
5. To retain product lookup on Product or Inventory record pages, leave **Scanner mode** set to `lookup`.

No Salesforce deployment or record-page activation was performed as part of this source change.

## Testing

Focused Salesforce test:

```powershell
cd D:\dms-salesforce
sf apex run test --target-org SFAOrg --tests DMSBarcodeScannerControllerTest DMSBarcodeDispatchVerificationTest DMSBarcodeTransactionValidationTest DMSDistributorInventoryResourceTest DMSInvoiceReturnResourceTest --wait 120
```

Frontend checks:

```powershell
cd D:\dms
npm run build
npm run lint
```

These commands are documented for execution after the Salesforce CLI/runtime permission gate is available. The runtime denied command execution during this task, so build, lint, Apex tests, deployment, and live org validation are not claimed as passed.

## Manual verification

1. Add the LWC to a test Primary Dispatch record page in `dispatch` mode.
2. Scan a barcode for a product on the dispatch. Confirm scanned quantity increases by one and remaining quantity decreases by one.
3. Scan an unknown barcode and a product not on the dispatch; both must be rejected.
4. Scan past the dispatched quantity; the extra scan must be rejected.
5. Test a unit mismatch or conversion factor other than one; the scanner must require manual verification.
6. Confirm `Inventory__c` is unchanged after scanning. Then use only the existing authorized dispatch confirmation to process primary stock.
7. In React, test secondary dispatch, GRN, and returns with known, unknown, and transaction-ineligible barcodes. Confirm scan-time validation rejects ineligible products and that the existing save/processing endpoints still reject invalid quantities.
8. Test the camera with permission granted, denied, and unsupported browser APIs. Confirm one detection increments only once and camera tracks stop when scanning ends.

## Remaining constraints

- Camera and USB scanning depend on browser support and camera permission; USB scanners must emulate keyboard input and send Enter after a complete barcode.
- Packaging-level barcodes and conversion mappings do not exist in the current product master. Do not treat a unit barcode as a carton barcode.
- React workflow scan counts are form state only, but each scan is validated by Salesforce before the count is incremented. The existing transaction-save APIs remain authoritative and revalidate the complete transaction. Primary-dispatch scan progress is persisted on dispatch lines.
- The scanner intentionally does not force barcode verification as a prerequisite to dispatch confirmation, because that would change the existing fulfillment authorization flow. If business policy requires mandatory complete scans, that must be approved and wired into the confirmation workflow separately.
