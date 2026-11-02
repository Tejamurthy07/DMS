@RestResource(urlMapping='/dms/v1/invoicing/*')
global without sharing class DMSInvoiceReturnResource {
    private static final Integer MAX_RECORDS = 200;

    @HttpGet
    global static void getDocuments() {
        RestResponse response = RestContext.response;
        Account distributor = findDistributor(getSessionToken());
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }
        try {
            List<Map<String, Object>> outlets = new List<Map<String, Object>>();
            for (Account outlet : [
                SELECT Id, Name
                FROM Account
                WHERE Distributor__c = :distributor.Id
                  AND Account_Category__c = 'Outlet'
                  AND Active__c = 'Yes'
                ORDER BY Name
                LIMIT :MAX_RECORDS
            ]) {
                outlets.add(new Map<String, Object>{ 'id' => outlet.Id, 'name' => outlet.Name });
            }

            List<Map<String, Object>> orders = new List<Map<String, Object>>();
            Set<Id> orderIds = new Set<Id>();
            Map<Id, Map<String, Object>> orderById = new Map<Id, Map<String, Object>>();
            for (Order salesOrder : [
                SELECT Id, OrderNumber, Account.Name, Type, Outlet__c, Outlet__r.Name,
                       EffectiveDate, TotalAmount,
                       DMS_Fulfillment_Warehouse__c, DMS_Allocation_Status__c
                FROM Order
                WHERE AccountId = :distributor.Id
                  AND Status = 'Activated'
                  AND (
                      Type = 'Primary Order'
                      OR (
                          Type = 'Secondary Order'
                          AND Outlet__c != null
                          AND Outlet__r.Distributor__c = :distributor.Id
                          AND Outlet__r.Account_Category__c = 'Outlet'
                      )
                  )
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ]) {
                Boolean isPrimaryOrder = salesOrder.Type == 'Primary Order';
                if (!isPrimaryOrder && salesOrder.Outlet__r == null) continue;
                Id billedAccountId = isPrimaryOrder
                    ? salesOrder.AccountId
                    : salesOrder.Outlet__c;
                String billedAccountName = isPrimaryOrder
                    ? salesOrder.Account.Name
                    : salesOrder.Outlet__r.Name;
                Map<String, Object> orderSummary = new Map<String, Object>{
                    'id' => salesOrder.Id,
                    'orderNumber' => salesOrder.OrderNumber,
                    'orderType' => salesOrder.Type,
                    'retailerId' => billedAccountId,
                    'retailerName' => billedAccountName,
                    'date' => salesOrder.EffectiveDate,
                    'totalAmount' => salesOrder.TotalAmount,
                    'fulfillmentWarehouseId' => salesOrder.DMS_Fulfillment_Warehouse__c,
                    'allocationStatus' => salesOrder.DMS_Allocation_Status__c,
                    'lines' => new List<Map<String, Object>>()
                };
                orders.add(orderSummary);
                orderIds.add(salesOrder.Id);
                orderById.put(salesOrder.Id, orderSummary);
            }
            Map<Id, Order_Scheme__c> appliedSchemesByProduct =
                new Map<Id, Order_Scheme__c>();
            for (Order_Scheme__c appliedScheme : [
                SELECT Scheme_Product__r.Product__c, Scheme__r.Scheme_Name__c
                FROM Order_Scheme__c
                WHERE Order__c IN :orderIds
                  AND Status__c = 'Applied'
                ORDER BY CreatedDate, Id
            ]) {
                Id productId = appliedScheme.Scheme_Product__r == null
                    ? null
                    : appliedScheme.Scheme_Product__r.Product__c;
                if (productId != null && !appliedSchemesByProduct.containsKey(productId)) {
                    appliedSchemesByProduct.put(productId, appliedScheme);
                }
            }
            for (OrderItem orderLine : [
                SELECT Id, OrderId, Product2Id, Product2.Name, Quantity,
                       UnitPrice, ListPrice, DMS_List_Price__c, Unit_of_Measure__c,
                       Paid_Quantity__c, Free_Quantity__c
                FROM OrderItem
                WHERE OrderId IN :orderIds
                ORDER BY CreatedDate, Id
            ]) {
                List<Map<String, Object>> orderLines =
                    (List<Map<String, Object>>) orderById.get(orderLine.OrderId).get('lines');
                Order_Scheme__c appliedScheme =
                    appliedSchemesByProduct.get(orderLine.Product2Id);
                orderLines.add(new Map<String, Object>{
                    'id' => orderLine.Id,
                    'productId' => orderLine.Product2Id,
                    'productName' => orderLine.Product2 == null ? null : orderLine.Product2.Name,
                    'quantity' => orderLine.Quantity,
                    'paidQuantity' => orderLine.Paid_Quantity__c,
                    'freeQuantity' => orderLine.Free_Quantity__c,
                    'unitPrice' => orderLine.UnitPrice,
                    'listPrice' => orderLine.DMS_List_Price__c == null
                        ? orderLine.ListPrice
                        : orderLine.DMS_List_Price__c,
                    'unitOfMeasure' => orderLine.Unit_of_Measure__c,
                    'schemeName' => appliedScheme == null || appliedScheme.Scheme__r == null
                        ? null
                        : appliedScheme.Scheme__r.Scheme_Name__c
                });
            }

            List<Map<String, Object>> invoices = new List<Map<String, Object>>();
            Set<Id> invoiceIds = new Set<Id>();
            Map<Id, Map<String, Object>> invoiceById = new Map<Id, Map<String, Object>>();
            for (DMS_Invoice__c invoice : [
                SELECT Id, Name, Invoice_Date__c, Retailer__c, Retailer__r.Name,
                       Retailer__r.Email__c,
                       Retailer__r.BillingStreet, Retailer__r.BillingCity,
                       Retailer__r.BillingState, Retailer__r.BillingPostalCode,
                       Retailer__r.BillingCountry, Retailer__r.ShippingStreet,
                       Retailer__r.ShippingCity, Retailer__r.ShippingState,
                       Retailer__r.ShippingPostalCode, Retailer__r.ShippingCountry,
                       Distributor__r.Name, Distributor__r.Phone,
                       Distributor__r.BillingStreet, Distributor__r.BillingCity,
                       Distributor__r.BillingState, Distributor__r.BillingPostalCode,
                       Distributor__r.BillingCountry,
                       Secondary_Order__c, Secondary_Order__r.OrderNumber,
                       Secondary_Order__r.Type, Secondary_Order__r.Status, Status__c,
                       Subtotal__c, Total_Discount__c, Taxable_Amount__c,
                       Tax_Amount__c, Invoice_Total__c,
                       Credited_Amount__c, Amount_Paid__c, Balance_Due__c, Posted_Date__c
                FROM DMS_Invoice__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ]) {
                Map<String, Object> summary = invoiceSummary(invoice);
                summary.put('lines', new List<Map<String, Object>>());
                invoices.add(summary);
                invoiceIds.add(invoice.Id);
                invoiceById.put(invoice.Id, summary);
            }
            for (DMS_Payment_Receipt__c receipt : [
                SELECT Id, Name, Invoice__c, Receipt_Date__c, Amount__c,
                       Balance_After_Receipt__c,
                       Payment_Method__c, Reference_Number__c, Notes__c
                FROM DMS_Payment_Receipt__c
                WHERE Distributor__c = :distributor.Id AND Invoice__c IN :invoiceIds
                ORDER BY Receipt_Date__c DESC, CreatedDate DESC
                LIMIT :MAX_RECORDS
            ]) {
                Map<String, Object> invoiceSummary = invoiceById.get(receipt.Invoice__c);
                if (invoiceSummary == null) continue;
                List<Map<String, Object>> receipts =
                    (List<Map<String, Object>>) invoiceSummary.get('paymentReceipts');
                receipts.add(new Map<String, Object>{
                    'id' => receipt.Id,
                    'number' => receipt.Name,
                    'date' => receipt.Receipt_Date__c,
                    'amount' => receipt.Amount__c,
                    'balanceDue' => receipt.Balance_After_Receipt__c,
                    'paymentMethod' => receipt.Payment_Method__c,
                    'referenceNumber' => receipt.Reference_Number__c,
                    'notes' => receipt.Notes__c
                });
            }
            Set<Id> invoicedOrderIds = new Set<Id>();
            for (DMS_Invoice__c invoice : [
                SELECT Secondary_Order__c
                FROM DMS_Invoice__c
                WHERE Secondary_Order__c IN :orderIds
            ]) {
                invoicedOrderIds.add(invoice.Secondary_Order__c);
            }
            for (Map<String, Object> orderSummary : orders) {
                Id listedOrderId = (Id) orderSummary.get('id');
                orderSummary.put(
                    'canGenerateInvoice',
                    orderSummary.get('orderType') == 'Secondary Order'
                        && !invoicedOrderIds.contains(listedOrderId)
                );
            }
            for (DMS_Invoice_Line__c invoiceLine : [
                SELECT Id, Invoice__c, Product__c, Product__r.Name,
                       Quantity__c, Unit_Price__c, Gross_Amount__c,
                       Discount_Amount__c, Taxable_Amount__c, Tax_Rate__c, Tax_Amount__c,
                       Line_Total__c, Unit_of_Measure__c
                FROM DMS_Invoice_Line__c
                WHERE Invoice__c IN :invoiceIds
                ORDER BY CreatedDate, Id
            ]) {
                List<Map<String, Object>> invoiceLines =
                    (List<Map<String, Object>>) invoiceById.get(invoiceLine.Invoice__c).get('lines');
                invoiceLines.add(new Map<String, Object>{
                    'id' => invoiceLine.Id,
                    'productId' => invoiceLine.Product__c,
                    'productName' => invoiceLine.Product__r == null
                        ? null
                        : invoiceLine.Product__r.Name,
                    'quantity' => invoiceLine.Quantity__c,
                    'unitPrice' => invoiceLine.Unit_Price__c,
                    'grossAmount' => invoiceLine.Gross_Amount__c,
                    'discount' => invoiceLine.Discount_Amount__c,
                    'taxableAmount' => invoiceLine.Taxable_Amount__c,
                    'taxRate' => invoiceLine.Tax_Rate__c,
                    'tax' => invoiceLine.Tax_Amount__c,
                    'total' => invoiceLine.Line_Total__c,
                    'unitOfMeasure' => invoiceLine.Unit_of_Measure__c
                });
            }

            List<DMS_Credit_Note__c> creditNoteRecords = [
                SELECT Id, Name, Credit_Note_Date__c, Invoice__c, Invoice__r.Name,
                       Retailer__c, Retailer__r.Name, Reason__c, Status__c,
                       Total_Credit_Amount__c, Posted_Date__c
                FROM DMS_Credit_Note__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ];
            Set<Id> creditNoteIds = new Set<Id>();
            for (DMS_Credit_Note__c creditNote : creditNoteRecords) creditNoteIds.add(creditNote.Id);
            Map<Id, String> creditApprovalStatuses = getApprovalStatuses(creditNoteIds);
            List<Map<String, Object>> creditNotes = new List<Map<String, Object>>();
            for (DMS_Credit_Note__c creditNote : creditNoteRecords) {
                creditNotes.add(new Map<String, Object>{
                    'id' => creditNote.Id,
                    'number' => creditNote.Name,
                    'date' => creditNote.Credit_Note_Date__c,
                    'invoiceId' => creditNote.Invoice__c,
                    'invoiceNumber' => creditNote.Invoice__r == null ? null : creditNote.Invoice__r.Name,
                    'retailerName' => creditNote.Retailer__r == null ? null : creditNote.Retailer__r.Name,
                    'reason' => creditNote.Reason__c,
                    'status' => effectiveApprovalStatus(
                        creditNote.Status__c,
                        creditApprovalStatuses.get(creditNote.Id)
                    ),
                    'amount' => creditNote.Total_Credit_Amount__c,
                    'postedDate' => creditNote.Posted_Date__c
                });
            }

            List<Return_Request__c> returnRecords = [
                SELECT Id, Name, Outlet__c, Outlet__r.Name, Return_Reason__c, Status__c,
                       DMS_Invoice__c, DMS_Invoice__r.Name, Remarks__c, Processed_Date__c
                FROM Return_Request__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ];
            Set<Id> returnIds = new Set<Id>();
            for (Return_Request__c returnRequest : returnRecords) returnIds.add(returnRequest.Id);
            Map<Id, String> returnApprovalStatuses = getApprovalStatuses(returnIds);
            List<Map<String, Object>> returns = new List<Map<String, Object>>();
            Map<Id, Map<String, Object>> returnById = new Map<Id, Map<String, Object>>();
            for (Return_Request__c returnRequest : returnRecords) {
                Map<String, Object> returnSummary = new Map<String, Object>{
                    'id' => returnRequest.Id,
                    'number' => returnRequest.Name,
                    'retailerName' => returnRequest.Outlet__r == null ? null : returnRequest.Outlet__r.Name,
                    'reason' => returnRequest.Return_Reason__c,
                    'status' => effectiveApprovalStatus(
                        returnRequest.Status__c,
                        returnApprovalStatuses.get(returnRequest.Id)
                    ),
                    'invoiceId' => returnRequest.DMS_Invoice__c,
                    'invoiceNumber' => returnRequest.DMS_Invoice__r == null
                        ? null
                        : returnRequest.DMS_Invoice__r.Name,
                    'remarks' => returnRequest.Remarks__c,
                    'processedDate' => returnRequest.Processed_Date__c,
                    'lines' => new List<Map<String, Object>>()
                };
                returns.add(returnSummary);
                returnIds.add(returnRequest.Id);
                returnById.put(returnRequest.Id, returnSummary);
            }
            for (Return_Item__c returnLine : [
                SELECT Id, Return_Request__c, DMS_Invoice_Line__c, Product__c,
                       Product__r.Name, Quantity__c, Unit_Price__c, Return_Amount__c,
                       Accepted_Quantity__c, Rejected_Quantity__c, Condition__c,
                       Restock_Decision__c
                FROM Return_Item__c
                WHERE Return_Request__c IN :returnIds
                ORDER BY CreatedDate, Id
            ]) {
                List<Map<String, Object>> returnLines =
                    (List<Map<String, Object>>) returnById.get(returnLine.Return_Request__c).get('lines');
                returnLines.add(new Map<String, Object>{
                    'id' => returnLine.Id,
                    'invoiceLineId' => returnLine.DMS_Invoice_Line__c,
                    'productId' => returnLine.Product__c,
                    'productName' => returnLine.Product__r == null ? null : returnLine.Product__r.Name,
                    'quantity' => returnLine.Quantity__c,
                    'unitPrice' => returnLine.Unit_Price__c,
                    'amount' => returnLine.Return_Amount__c,
                    'acceptedQuantity' => returnLine.Accepted_Quantity__c,
                    'rejectedQuantity' => returnLine.Rejected_Quantity__c,
                    'condition' => returnLine.Condition__c,
                    'restockDecision' => returnLine.Restock_Decision__c
                });
            }

            List<Map<String, Object>> warehouses = new List<Map<String, Object>>();
            for (Warehouse__c warehouse : [
                SELECT Id, Name
                FROM Warehouse__c
                WHERE Distributor__c = :distributor.Id
                  AND Warehouse_Type__c = 'Distributor Warehouse'
                  AND Warehouse_Status__c = 'Active'
                ORDER BY Name
                LIMIT :MAX_RECORDS
            ]) {
                warehouses.add(new Map<String, Object>{
                    'id' => warehouse.Id,
                    'name' => warehouse.Name
                });
            }

            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'outlets' => outlets,
                'orders' => orders,
                'warehouses' => warehouses,
                'invoices' => invoices,
                'creditNotes' => creditNotes,
                'returns' => returns
            });
        } catch (Exception error) {
            System.debug(LoggingLevel.ERROR,
                'DMS invoice and return data load failed: ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'Invoice and return data could not be loaded. Please try again.'
            });
        }
    }

    @HttpPost
    global static void postDocumentAction() {
        RestResponse response = RestContext.response;
        Account distributor = findDistributor(getSessionToken());
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }

        Savepoint savepoint = Database.setSavepoint();
        String stage = 'request validation';
        try {
            Map<String, Object> payload = readPayload();
            if (payload == null) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'A valid JSON request body is required.'
                });
                return;
            }
            String action = stringValue(payload.get('action'));
            if (action == 'createInvoice') {
                createInvoice(distributor, payload, response);
            } else if (action == 'postInvoice') {
                stage = 'invoice posting';
                postInvoice(distributor, payload, response);
            } else if (action == 'downloadReceipt') {
                stage = 'payment receipt PDF generation';
                downloadReceipt(distributor, payload, response);
            } else if (action == 'emailReceipt') {
                stage = 'payment receipt email';
                emailReceipt(distributor, payload, response);
            } else if (action == 'recordPayment') {
                stage = 'payment receipt recording';
                recordPayment(distributor, payload, response);
            } else if (action == 'cancelInvoice') {
                cancelInvoice(distributor, payload, response);
            } else if (action == 'createCreditNote') {
                createCreditNote(distributor, payload, response);
            } else if (action == 'submitCreditNote') {
                submitCreditNote(distributor, payload, response);
            } else if (action == 'postCreditNote') {
                postCreditNote(distributor, payload, response);
            } else if (action == 'validateReturnBarcode') {
                validateReturnBarcode(distributor, payload, response);
            } else if (action == 'createReturn') {
                createReturn(distributor, payload, response);
            } else if (action == 'submitReturn') {
                submitReturn(distributor, payload, response);
            } else if (action == 'inspectReturn') {
                inspectReturn(distributor, payload, response);
            } else if (action == 'completeReturn') {
                stage = 'return completion';
                completeReturn(distributor, payload, response);
            } else {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The requested invoicing action is not supported.'
                });
            }
        } catch (DmlException error) {
            Database.rollback(savepoint);
            String message = error.getNumDml() > 0 ? error.getDmlMessage(0) : error.getMessage();
            System.debug(LoggingLevel.ERROR,
                'DMS document operation failed during ' + stage + ': ' + message +
                '\n' + error.getStackTraceString());
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'The document operation failed: ' + message
            });
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR,
                'DMS document operation failed during ' + stage + ': ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The document operation failed during ' + stage + '. Please try again.'
            });
        }
    }

    private static void createInvoice(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id orderId = parseId(payload.get('orderId'));
        Id warehouseId = parseId(payload.get('warehouseId'));
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || orderId == null || warehouseId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A request key, eligible order, and warehouse are required.'
            });
            return;
        }

        List<DMS_Invoice__c> idempotentInvoices = [
            SELECT Id, Name, Status__c, Secondary_Order__c
            FROM DMS_Invoice__c
            WHERE Request_Key__c = :requestKey
              AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (!idempotentInvoices.isEmpty()) {
            if (idempotentInvoices[0].Secondary_Order__c != orderId) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'This request key is already associated with a different order.'
                });
                return;
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'invoice' => getInvoicePreview(
                    idempotentInvoices[0].Id,
                    distributor.Id
                ),
                'message' => 'The invoice draft already exists.'
            });
            return;
        }

        List<Order> matchingOrders = [
            SELECT Id, OrderNumber, AccountId, Account.Name, Type, Status, Outlet__c,
                   Outlet__r.Name, Outlet__r.Distributor__c,
                   Outlet__r.Account_Category__c, TotalAmount, DMS_Fulfillment_Warehouse__c,
                   DMS_Allocation_Status__c
            FROM Order
            WHERE Id = :orderId
              AND AccountId = :distributor.Id
              AND Type IN ('Primary Order', 'Secondary Order')
              AND Status IN ('Draft', 'Activated')
            LIMIT 1
            FOR UPDATE
        ];
        if (matchingOrders.isEmpty()
            || (matchingOrders[0].Type == 'Secondary Order'
                && (matchingOrders[0].Outlet__c == null
                    || matchingOrders[0].Outlet__r == null
                    || matchingOrders[0].Outlet__r.Distributor__c != distributor.Id
                    || matchingOrders[0].Outlet__r.Account_Category__c != 'Outlet'))) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'The Draft or Activated order is unavailable for this distributor.'
            });
            return;
        }
        Order salesOrder = matchingOrders[0];
        if (salesOrder.Type == 'Primary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary invoices are created by the company through Salesforce. The DMS portal only displays the resulting invoice.'
            });
            return;
        }
        if (salesOrder.DMS_Fulfillment_Warehouse__c != null
            && salesOrder.DMS_Fulfillment_Warehouse__c != warehouseId) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Use the warehouse allocated to this order.'
            });
            return;
        }
        if (salesOrder.DMS_Allocation_Status__c == 'Reserved'
            && salesOrder.DMS_Fulfillment_Warehouse__c == null) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The reserved order has no fulfillment warehouse. Reallocate it before invoicing.'
            });
            return;
        }
        if ([SELECT Id FROM Warehouse__c
             WHERE Id = :warehouseId AND Distributor__c = :distributor.Id
               AND Warehouse_Type__c = 'Distributor Warehouse'
               AND Warehouse_Status__c = 'Active' LIMIT 1].isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Select an active warehouse belonging to your distributor account.'
            });
            return;
        }
        List<DMS_Invoice__c> existingOrderInvoices = [
            SELECT Id, Name, Status__c
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c = :salesOrder.Id
              AND Distributor__c = :distributor.Id
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!existingOrderInvoices.isEmpty()) {
            if (salesOrder.Status == 'Draft') {
                salesOrder.Status = 'Activated';
                update salesOrder;
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'invoice' => getInvoicePreview(
                    existingOrderInvoices[0].Id,
                    distributor.Id
                ),
                'message' => 'This order already has an invoice. The existing invoice was retrieved.'
            });
            return;
        }

        List<OrderItem> orderItems = [
            SELECT Id, Product2Id, Product2.Name, Product2.IsActive,
                   Product2.DMS_Tax_Rate__c, Quantity, UnitPrice, ListPrice,
                   DMS_List_Price__c, Unit_of_Measure__c, DMS_Tax_Rate__c,
                   DMS_Tax_Amount__c
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ];
        if (orderItems.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'The order does not contain any invoiceable products.'
            });
            return;
        }
        if (salesOrder.Status == 'Activated') {
            String reservationError = validateInvoiceReservation(
                salesOrder,
                warehouseId,
                orderItems,
                distributor.Id
            );
            if (reservationError != null) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => reservationError
                });
                return;
            }
        }

        Decimal subtotal = 0;
        Decimal totalDiscount = 0;
        Decimal taxableAmount = 0;
        Decimal taxAmount = 0;
        List<DMS_Invoice_Line__c> invoiceLines = new List<DMS_Invoice_Line__c>();
        for (OrderItem item : orderItems) {
            Decimal listPrice = item.DMS_List_Price__c == null
                ? item.ListPrice
                : item.DMS_List_Price__c;
            if (item.Product2 == null || !item.Product2.IsActive
                || item.Quantity == null || item.Quantity <= 0
                || item.UnitPrice == null || item.UnitPrice < 0
                || listPrice == null || listPrice < item.UnitPrice) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The order contains an invalid product, quantity, price, or discount.'
                });
                return;
            }
            Decimal lineGross = (listPrice * item.Quantity).setScale(2);
            Decimal lineDiscount = ((listPrice - item.UnitPrice) * item.Quantity).setScale(2);
            Decimal lineTaxable = (item.UnitPrice * item.Quantity).setScale(2);
            Decimal taxRate = item.DMS_Tax_Rate__c == null
                ? (item.Product2.DMS_Tax_Rate__c == null
                    ? 0
                    : item.Product2.DMS_Tax_Rate__c)
                : item.DMS_Tax_Rate__c;
            if (taxRate < 0 || taxRate > 100) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'A product has an invalid configured tax rate.'
                });
                return;
            }
            Decimal lineTax = item.DMS_Tax_Amount__c == null
                ? (lineTaxable * taxRate / 100).setScale(2)
                : item.DMS_Tax_Amount__c.setScale(2);
            if (lineTax < 0) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'An order line has an invalid tax amount.'
                });
                return;
            }
            Decimal lineTotal = lineTaxable + lineTax;
            subtotal += lineGross;
            totalDiscount += lineDiscount;
            taxableAmount += lineTaxable;
            taxAmount += lineTax;
            invoiceLines.add(new DMS_Invoice_Line__c(
                Order_Line_Item__c = item.Id,
                Product__c = item.Product2Id,
                Quantity__c = item.Quantity,
                Unit_Price__c = item.UnitPrice,
                Gross_Amount__c = lineGross,
                Discount_Amount__c = lineDiscount,
                Taxable_Amount__c = lineTaxable,
                Tax_Rate__c = taxRate,
                Tax_Amount__c = lineTax,
                Line_Total__c = lineTotal,
                Unit_of_Measure__c = item.Unit_of_Measure__c
            ));
        }
        subtotal = subtotal.setScale(2);
        totalDiscount = totalDiscount.setScale(2);
        taxableAmount = taxableAmount.setScale(2);
        taxAmount = taxAmount.setScale(2);
        if (salesOrder.Status == 'Draft') {
            salesOrder.Status = 'Activated';
            update salesOrder;
        }
        DMS_Invoice__c invoice = new DMS_Invoice__c(
            Invoice_Date__c = Date.today(),
            Distributor__c = distributor.Id,
            Retailer__c = salesOrder.Type == 'Primary Order'
                ? salesOrder.AccountId
                : salesOrder.Outlet__c,
            Secondary_Order__c = salesOrder.Id,
            Warehouse__c = warehouseId,
            Status__c = 'Draft',
            Subtotal__c = subtotal,
            Total_Discount__c = totalDiscount,
            Taxable_Amount__c = taxableAmount,
            Tax_Amount__c = taxAmount,
            Invoice_Total__c = taxableAmount + taxAmount,
            Credited_Amount__c = 0,
            Amount_Paid__c = 0,
            Balance_Due__c = taxableAmount + taxAmount,
            Stock_Deduction_Status__c = 'Pending Dispatch',
            Request_Key__c = requestKey
        );
        insert invoice;
        for (DMS_Invoice_Line__c invoiceLine : invoiceLines) {
            invoiceLine.Invoice__c = invoice.Id;
        }
        insert invoiceLines;
        writeResponse(response, 201, new Map<String, Object>{
            'success' => true,
            'invoice' => getInvoicePreview(invoice.Id, distributor.Id)
        });
    }

    private static Map<String, Object> getInvoicePreview(Id invoiceId, Id distributorId) {
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Invoice_Date__c, Status__c, Secondary_Order__c,
                   Secondary_Order__r.OrderNumber, Secondary_Order__r.Type,
                   Retailer__c, Retailer__r.Name, Subtotal__c, Total_Discount__c,
                   Taxable_Amount__c, Tax_Amount__c, Invoice_Total__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributorId
            LIMIT 1
        ];
        if (invoices.isEmpty()) {
            throw new RequestException('The saved invoice could not be retrieved.');
        }
        DMS_Invoice__c invoice = invoices[0];
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        for (DMS_Invoice_Line__c line : [
            SELECT Id, Product__r.Name, Quantity__c, Unit_Price__c,
                   Gross_Amount__c, Discount_Amount__c, Taxable_Amount__c,
                   Tax_Rate__c, Tax_Amount__c, Line_Total__c, Unit_of_Measure__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
            ORDER BY CreatedDate, Id
        ]) {
            lines.add(new Map<String, Object>{
                'id' => line.Id,
                'productName' => line.Product__r == null ? null : line.Product__r.Name,
                'quantity' => line.Quantity__c,
                'unitPrice' => line.Unit_Price__c,
                'grossAmount' => line.Gross_Amount__c,
                'discount' => line.Discount_Amount__c,
                'taxableAmount' => line.Taxable_Amount__c,
                'taxRate' => line.Tax_Rate__c,
                'tax' => line.Tax_Amount__c,
                'total' => line.Line_Total__c,
                'unitOfMeasure' => line.Unit_of_Measure__c
            });
        }
        return new Map<String, Object>{
            'id' => invoice.Id,
            'number' => invoice.Name,
            'date' => invoice.Invoice_Date__c,
            'status' => invoice.Status__c,
            'orderId' => invoice.Secondary_Order__c,
            'orderNumber' => invoice.Secondary_Order__r == null
                ? null
                : invoice.Secondary_Order__r.OrderNumber,
            'salesType' => invoice.Secondary_Order__r == null
                ? null
                : (invoice.Secondary_Order__r.Type == 'Primary Order'
                    ? 'Primary'
                    : 'Secondary'),
            'customerName' => invoice.Retailer__r == null
                ? null
                : invoice.Retailer__r.Name,
            'subtotal' => invoice.Subtotal__c,
            'discount' => invoice.Total_Discount__c,
            'taxableAmount' => invoice.Taxable_Amount__c,
            'tax' => invoice.Tax_Amount__c,
            'total' => invoice.Invoice_Total__c,
            'lines' => lines
        };
    }

    private static String validateInvoiceReservation(
        Order salesOrder,
        Id warehouseId,
        List<OrderItem> orderItems,
        Id distributorId
    ) {
        String reservationPattern = 'DMS-RES-' + String.valueOf(salesOrder.Id) + '-%';
        Set<String> reservationTypes = new Set<String>{'Stock Reservation', 'Stock Release'};
        Map<String, Decimal> activeByReferenceInventory = new Map<String, Decimal>();
        Map<Id, Id> productByInventory = new Map<Id, Id>();
        Map<Id, Id> warehouseByInventory = new Map<Id, Id>();

        for (Inventory_Transaction__c reservationRecord : [
            SELECT Inventory__c, Inventory__r.Product__c, Inventory__r.Warehouse__c,
                   Transaction_Type__c, Quantity__c, Reference_Number__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :reservationPattern
              AND Transaction_Type__c IN :reservationTypes
              AND Inventory__r.Warehouse__r.Distributor__c = :distributorId
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ORDER BY CreatedDate, Id
        ]) {
            if (reservationRecord.Inventory__c == null
                || reservationRecord.Quantity__c == null
                || reservationRecord.Quantity__c <= 0) {
                return 'The order reservation ledger is invalid. Contact your administrator.';
            }
            String key = reservationRecord.Reference_Number__c
                + ':' + reservationRecord.Inventory__c;
            Decimal activeQuantity = activeByReferenceInventory.containsKey(key)
                ? activeByReferenceInventory.get(key)
                : 0;
            activeByReferenceInventory.put(
                key,
                activeQuantity + (
                    reservationRecord.Transaction_Type__c == 'Stock Reservation'
                        ? reservationRecord.Quantity__c
                        : -reservationRecord.Quantity__c
                )
            );
            productByInventory.put(
                reservationRecord.Inventory__c,
                reservationRecord.Inventory__r.Product__c
            );
            warehouseByInventory.put(
                reservationRecord.Inventory__c,
                reservationRecord.Inventory__r.Warehouse__c
            );
        }

        Map<Id, Decimal> activeByProduct = new Map<Id, Decimal>();
        Boolean hasActiveReservation = false;
        for (String key : activeByReferenceInventory.keySet()) {
            Decimal activeQuantity = activeByReferenceInventory.get(key);
            if (activeQuantity < 0) {
                return 'The order reservation ledger is inconsistent. Contact your administrator.';
            }
            if (activeQuantity == 0) continue;
            Id inventoryId = (Id) key.substring(key.lastIndexOf(':') + 1);
            Id productId = productByInventory.get(inventoryId);
            if (productId == null || warehouseByInventory.get(inventoryId) != warehouseId) {
                return 'The active reservation does not match the invoice warehouse or product.';
            }
            hasActiveReservation = true;
            activeByProduct.put(
                productId,
                (activeByProduct.containsKey(productId) ? activeByProduct.get(productId) : 0)
                    + activeQuantity
            );
        }

        if (salesOrder.DMS_Allocation_Status__c == 'Reserved' && !hasActiveReservation) {
            return 'The order is marked Reserved, but no active reservation was found.';
        }
        if (!hasActiveReservation) return null;

        Map<Id, Decimal> orderedByProduct = new Map<Id, Decimal>();
        for (OrderItem item : orderItems) {
            Decimal quantity = orderedByProduct.containsKey(item.Product2Id)
                ? orderedByProduct.get(item.Product2Id)
                : 0;
            orderedByProduct.put(item.Product2Id, quantity + item.Quantity);
        }
        if (orderedByProduct.size() != activeByProduct.size()) {
            return 'The active reservation quantities do not match the order lines.';
        }
        for (Id productId : orderedByProduct.keySet()) {
            if (activeByProduct.get(productId) != orderedByProduct.get(productId)) {
                return 'The active reservation quantities do not match the order lines.';
            }
        }
        return null;
    }

    private static void postInvoice(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id invoiceId = parseId(payload.get('invoiceId'));
        if (invoiceId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid invoiceId is required.'
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Status__c, Secondary_Order__c, Retailer__c,
                   Distributor__c, Stock_Deduction_Status__c,
                   Secondary_Order__r.Type
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Invoice not found.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoices[0];
        if (invoice.Secondary_Order__r != null
            && invoice.Secondary_Order__r.Type == 'Primary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary invoice status is managed by the company in Salesforce and is read-only in the distributor portal.'
            });
            return;
        }
        if (invoice.Status__c == 'Posted') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'message' => 'Invoice has already been posted.',
                'invoiceId' => invoice.Id,
                'status' => invoice.Status__c
            });
            return;
        }
        if (invoice.Status__c != 'Draft') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only draft invoices can be posted.'
            });
            return;
        }
        List<Order> eligibleOrders = [
            SELECT Id, Type, AccountId, Outlet__c, Outlet__r.Distributor__c,
                   Outlet__r.Account_Category__c
            FROM Order
            WHERE Id = :invoice.Secondary_Order__c
              AND AccountId = :distributor.Id
              AND Status = 'Activated'
              AND Type IN ('Primary Order', 'Secondary Order')
            LIMIT 1
            FOR UPDATE
        ];
        if (eligibleOrders.isEmpty()
            || (eligibleOrders[0].Type == 'Primary Order'
                && eligibleOrders[0].AccountId != invoice.Retailer__c)
            || (eligibleOrders.size() == 1
                && eligibleOrders[0].Type == 'Secondary Order'
                && (eligibleOrders[0].Outlet__c != invoice.Retailer__c
                    || eligibleOrders[0].Outlet__r == null
                    || eligibleOrders[0].Outlet__r.Distributor__c != distributor.Id
                    || eligibleOrders[0].Outlet__r.Account_Category__c != 'Outlet'))) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The linked order is no longer eligible.'
            });
            return;
        }
        if ([SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoice.Id LIMIT 1].isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'An invoice must contain at least one line before posting.'
            });
            return;
        }
        invoice.Status__c = 'Posted';
        invoice.Posted_Date__c = System.now();
        if (String.isBlank(invoice.Stock_Deduction_Status__c)) {
            invoice.Stock_Deduction_Status__c = 'Pending Dispatch';
        }
        update invoice;
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => 'Invoice posted. Inventory will be deducted when the dispatch is confirmed.',
            'invoiceId' => invoice.Id,
            'status' => invoice.Status__c
        });
    }

    private static void postInvoiceWithLegacyStockDeduction(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id invoiceId = parseId(payload.get('invoiceId'));
        if (invoiceId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid invoiceId is required.'
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Status__c, Warehouse__c, Secondary_Order__c, Retailer__c,
                   Invoice_Total__c, Distributor__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Invoice not found.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoices[0];
        if (invoice.Status__c == 'Posted') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'message' => 'Invoice has already been posted.',
                'invoiceId' => invoice.Id,
                'status' => invoice.Status__c
            });
            return;
        }
        if (invoice.Status__c != 'Draft') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only draft invoices can be posted.'
            });
            return;
        }
        List<Order> eligibleOrders = [
            SELECT Id, OrderNumber, Status, Type, Outlet__c
            FROM Order
            WHERE Id = :invoice.Secondary_Order__c
              AND AccountId = :distributor.Id
              AND Status = 'Activated'
              AND Type = 'Secondary Order'
              AND Outlet__c = :invoice.Retailer__c
            LIMIT 1
            FOR UPDATE
        ];
        if (eligibleOrders.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The linked secondary order is no longer eligible.'
            });
            return;
        }
        List<DMS_Invoice_Line__c> lines = [
            SELECT Id, Product__c, Quantity__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
        ];
        if (lines.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'An invoice must contain at least one line before posting.'
            });
            return;
        }

        Map<Id, Decimal> quantitiesByProduct = new Map<Id, Decimal>();
        for (DMS_Invoice_Line__c line : lines) {
            if (line.Product__c == null || line.Quantity__c == null || line.Quantity__c <= 0) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The invoice contains an invalid product or quantity.'
                });
                return;
            }
            Decimal currentQuantity = quantitiesByProduct.containsKey(line.Product__c)
                ? quantitiesByProduct.get(line.Product__c)
                : 0;
            quantitiesByProduct.put(line.Product__c, currentQuantity + line.Quantity__c);
        }

        String reservationPattern = 'DMS-RES-' + String.valueOf(eligibleOrders[0].Id) + '-%';
        Set<String> reservationTypes = new Set<String>{'Stock Reservation', 'Stock Release'};
        Map<Id, Decimal> reservationQuantityByInventory = new Map<Id, Decimal>();
        Map<Id, Id> reservedProductByInventory = new Map<Id, Id>();
        Map<Id, Id> reservedWarehouseByInventory = new Map<Id, Id>();
        Map<String, Decimal> reservationQuantityByReferenceInventory = new Map<String, Decimal>();
        Map<String, Id> inventoryByReferenceInventory = new Map<String, Id>();
        for (Inventory_Transaction__c reservationTransaction : [
            SELECT Inventory__c, Inventory__r.Product__c, Inventory__r.Warehouse__c,
                   Transaction_Type__c, Quantity__c, Reference_Number__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :reservationPattern
              AND Transaction_Type__c IN :reservationTypes
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
        ]) {
            Decimal currentQuantity = reservationQuantityByInventory.containsKey(
                reservationTransaction.Inventory__c
            )
                ? reservationQuantityByInventory.get(reservationTransaction.Inventory__c)
                : 0;
            Decimal transactionQuantity = reservationTransaction.Quantity__c == null
                ? 0
                : reservationTransaction.Quantity__c;
            reservationQuantityByInventory.put(
                reservationTransaction.Inventory__c,
                currentQuantity + (
                    reservationTransaction.Transaction_Type__c == 'Stock Reservation'
                        ? transactionQuantity
                        : -transactionQuantity
                )
            );
            String referenceInventoryKey = reservationTransaction.Reference_Number__c
                + ':' + reservationTransaction.Inventory__c;
            Decimal currentReferenceQuantity = reservationQuantityByReferenceInventory.containsKey(
                referenceInventoryKey
            )
                ? reservationQuantityByReferenceInventory.get(referenceInventoryKey)
                : 0;
            reservationQuantityByReferenceInventory.put(
                referenceInventoryKey,
                currentReferenceQuantity + (
                        reservationTransaction.Transaction_Type__c == 'Stock Reservation'
                            ? transactionQuantity
                            : -transactionQuantity
                )
            );
            inventoryByReferenceInventory.put(
                referenceInventoryKey,
                reservationTransaction.Inventory__c
            );
            reservedProductByInventory.put(
                reservationTransaction.Inventory__c,
                reservationTransaction.Inventory__r.Product__c
            );
            reservedWarehouseByInventory.put(
                reservationTransaction.Inventory__c,
                reservationTransaction.Inventory__r.Warehouse__c
            );
        }
        Map<Id, Decimal> activeReservationByProduct = new Map<Id, Decimal>();
        Boolean hasActiveReservation = false;
        for (Id inventoryId : reservationQuantityByInventory.keySet()) {
            Decimal reservedQuantity = reservationQuantityByInventory.get(inventoryId);
            if (reservedQuantity < 0) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The order reservation ledger is inconsistent. Contact your administrator.'
                });
                return;
            }
            if (reservedQuantity == 0) continue;
            hasActiveReservation = true;
            if (reservedWarehouseByInventory.get(inventoryId) != invoice.Warehouse__c) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Release the order reservation or use its fulfillment warehouse before posting this invoice.'
                });
                return;
            }
            Id productId = reservedProductByInventory.get(inventoryId);
            activeReservationByProduct.put(
                productId,
                (activeReservationByProduct.containsKey(productId)
                    ? activeReservationByProduct.get(productId)
                    : 0) + reservedQuantity
            );
        }
        if (hasActiveReservation) {
            for (Id productId : quantitiesByProduct.keySet()) {
                if (activeReservationByProduct.get(productId) != quantitiesByProduct.get(productId)) {
                    writeResponse(response, 409, new Map<String, Object>{
                        'success' => false,
                        'message' => 'The invoice quantities do not match the active order reservation. Release and reserve the order again.'
                    });
                    return;
                }
            }
            for (Id productId : activeReservationByProduct.keySet()) {
                if (!quantitiesByProduct.containsKey(productId)) {
                    writeResponse(response, 409, new Map<String, Object>{
                        'success' => false,
                        'message' => 'The invoice lines do not match the active order reservation. Release and reserve the order again.'
                    });
                    return;
                }
            }
        }

        List<Inventory__c> inventoryRecords = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c, Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Warehouse__c = :invoice.Warehouse__c
              AND Product__c IN :quantitiesByProduct.keySet()
            FOR UPDATE
        ];
        Map<Id, Inventory__c> inventoryByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c stock : inventoryRecords) {
            if (inventoryByProduct.containsKey(stock.Product__c)) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Duplicate inventory balances exist for a product and warehouse.'
                });
                return;
            }
            inventoryByProduct.put(stock.Product__c, stock);
        }
        for (Id productId : quantitiesByProduct.keySet()) {
            Inventory__c stock = inventoryByProduct.get(productId);
            Boolean insufficient = stock == null;
            if (stock != null && hasActiveReservation) {
                Decimal orderReserved = activeReservationByProduct.get(productId);
                insufficient = orderReserved == null
                    || stock.Reserved_Quantity__c == null
                    || stock.Reserved_Quantity__c < quantitiesByProduct.get(productId);
            } else if (stock != null) {
                insufficient = stock.Available_Quantity__c == null
                    || stock.Available_Quantity__c < quantitiesByProduct.get(productId);
            }
            if (insufficient) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Available stock is insufficient to post this invoice.'
                });
                return;
            }
        }

        List<Inventory_Transaction__c> transactions = new List<Inventory_Transaction__c>();
        for (Id productId : quantitiesByProduct.keySet()) {
            Decimal quantity = quantitiesByProduct.get(productId);
            Inventory__c stock = inventoryByProduct.get(productId);
            if (hasActiveReservation) {
                stock.Reserved_Quantity__c -= quantity;
            } else {
                stock.Available_Quantity__c -= quantity;
            }
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = stock.Id,
                Transaction_Type__c = 'Secondary Order Sale',
                Quantity__c = quantity,
                Transaction_Date__c = System.now(),
                Reference_Number__c = invoice.Name,
                Transaction_Description__c = 'Posted invoice stock deduction',
                DMS_Invoice__c = invoice.Id
            ));
        }
        if (hasActiveReservation) {
            for (String referenceInventoryKey : reservationQuantityByReferenceInventory.keySet()) {
                Decimal reservedQuantity = reservationQuantityByReferenceInventory.get(referenceInventoryKey);
                if (reservedQuantity <= 0) continue;
                Id inventoryId = inventoryByReferenceInventory.get(referenceInventoryKey);
                transactions.add(new Inventory_Transaction__c(
                    Inventory__c = inventoryId,
                    Transaction_Type__c = 'Stock Release',
                    Quantity__c = reservedQuantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = referenceInventoryKey.substring(
                        0,
                        referenceInventoryKey.indexOf(':')
                    ),
                    Transaction_Description__c = 'Reservation consumed when invoice ' + invoice.Name + ' was posted',
                    DMS_Invoice__c = invoice.Id
                ));
            }
        }
        Savepoint savepoint = Database.setSavepoint();
        try {
            update inventoryRecords;
            insert transactions;
            invoice.Status__c = 'Posted';
            invoice.Posted_Date__c = System.now();
            update invoice;
        } catch (Exception error) {
            Database.rollback(savepoint);
            throw error;
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => 'Invoice posted and inventory deducted.',
            'invoiceId' => invoice.Id,
            'status' => invoice.Status__c
        });
    }

    private static void cancelInvoice(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id invoiceId = parseId(payload.get('invoiceId'));
        if (invoiceId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid invoiceId is required.'
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Status__c, Secondary_Order__c, Secondary_Order__r.Type
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Invoice not found.'
            });
            return;
        }
        if (invoices[0].Secondary_Order__r != null
            && invoices[0].Secondary_Order__r.Type == 'Primary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary invoice status is managed by the company in Salesforce and is read-only in the distributor portal.'
            });
            return;
        }
        if (invoices[0].Status__c != 'Draft') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only draft invoices can be cancelled.'
            });
            return;
        }
        if (invoices[0].Secondary_Order__c != null && ![
            SELECT Id
            FROM ProcessInstance
            WHERE TargetObjectId = :invoices[0].Secondary_Order__c
              AND Status = 'Pending'
            LIMIT 1
        ].isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'A Draft invoice cannot be cancelled while its order is pending approval.'
            });
            return;
        }
        invoices[0].Status__c = 'Cancelled';
        update invoices[0];
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'status' => invoices[0].Status__c
        });
    }

    private static void createCreditNote(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id invoiceId = parseId(payload.get('invoiceId'));
        String reason = stringValue(payload.get('reason'));
        Decimal amount = decimalValue(payload.get('amount'));
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || invoiceId == null || String.isBlank(reason) || amount == null || amount <= 0) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A request key, invoice, reason, and positive credit amount are required.'
            });
            return;
        }
        if (!new Set<String>{
            'Product Return', 'Damaged Goods', 'Expired Goods', 'Incorrect Pricing',
            'Tax Correction', 'Discount Correction', 'Scheme Adjustment',
            'Other Approved Adjustment'
        }.contains(reason)) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Select a supported credit-note reason.'
            });
            return;
        }
        amount = amount.setScale(2);
        List<DMS_Credit_Note__c> duplicates = [
            SELECT Id, Name, Status__c
            FROM DMS_Credit_Note__c
            WHERE Request_Key__c = :requestKey AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (!duplicates.isEmpty()) {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'creditNote' => new Map<String, Object>{
                    'id' => duplicates[0].Id,
                    'number' => duplicates[0].Name,
                    'status' => duplicates[0].Status__c
                }
            });
            return;
        }
        List<DMS_Invoice__c> invoiceRecords = [
            SELECT Id, Name, Status__c, Distributor__c, Retailer__c,
                   Invoice_Total__c, Credited_Amount__c, Amount_Paid__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoiceRecords.isEmpty()
            || !new Set<String>{'Posted', 'Partially Credited'}.contains(invoiceRecords[0].Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Credit notes can only reference a posted invoice belonging to your distributor.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoiceRecords[0];
        Decimal alreadyCredited = invoice.Credited_Amount__c == null ? 0 : invoice.Credited_Amount__c;
        Decimal alreadyPaid = invoice.Amount_Paid__c == null ? 0 : invoice.Amount_Paid__c;
        if (alreadyCredited + alreadyPaid + amount > invoice.Invoice_Total__c) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The proposed credit exceeds the invoice balance remaining after payments.'
            });
            return;
        }
        Id approverId = getConfiguredApprovalUserId();
        DMS_Credit_Note__c creditNote = new DMS_Credit_Note__c(
            OwnerId = distributor.OwnerId,
            Credit_Note_Date__c = Date.today(),
            Invoice__c = invoice.Id,
            Distributor__c = distributor.Id,
            Retailer__c = invoice.Retailer__c,
            Reason__c = reason,
            Status__c = 'Draft',
            Subtotal__c = amount,
            Discount_Adjustment__c = 0,
            Tax_Adjustment__c = 0,
            Total_Credit_Amount__c = amount,
            Request_Key__c = requestKey,
            Approver__c = approverId
        );
        insert creditNote;
        writeResponse(response, 201, new Map<String, Object>{
            'success' => true,
            'creditNote' => new Map<String, Object>{
                'id' => creditNote.Id,
                'number' => creditNote.Name,
                'status' => creditNote.Status__c,
                'amount' => creditNote.Total_Credit_Amount__c
            }
        });
    }

    private static void submitCreditNote(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id creditNoteId = parseId(payload.get('creditNoteId'));
        if (creditNoteId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid creditNoteId is required.'
            });
            return;
        }
        List<DMS_Credit_Note__c> creditNotes = [
            SELECT Id, Name, Status__c, Distributor__c, Approver__c
            FROM DMS_Credit_Note__c
            WHERE Id = :creditNoteId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (creditNotes.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Credit note not found.'
            });
            return;
        }
        DMS_Credit_Note__c creditNote = creditNotes[0];
        if (creditNote.Status__c != 'Draft') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only draft credit notes can be submitted for approval.'
            });
            return;
        }
        String approvalStatus = getApprovalStatuses(new Set<Id>{creditNote.Id}).get(creditNote.Id);
        if (approvalStatus == 'Pending' || approvalStatus == 'Approved') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => approvalStatus == 'Approved' ? 'Approved' : 'Submitted'
            });
            return;
        }
        Id approverId = getConfiguredApprovalUserId();
        if (approverId == null) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The configured active Salesforce approver could not be found.'
            });
            return;
        }
        if (creditNote.Approver__c != approverId) {
            creditNote.Approver__c = approverId;
            update creditNote;
        }
        List<String> approvalErrors = submitForApproval(
            creditNote.Id,
            distributor.OwnerId,
            'Credit note submitted from the DMS distributor portal.'
        );
        if (!approvalErrors.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Salesforce approval submission failed: ' +
                    String.join(approvalErrors, ' ')
            });
            return;
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'status' => 'Submitted'
        });
    }

    private static void postCreditNote(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id creditNoteId = parseId(payload.get('creditNoteId'));
        if (creditNoteId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid creditNoteId is required.'
            });
            return;
        }
        List<DMS_Credit_Note__c> creditNotes = [
            SELECT Id, Name, Invoice__c, Status__c, Total_Credit_Amount__c,
                   Posted_Date__c
            FROM DMS_Credit_Note__c
            WHERE Id = :creditNoteId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (creditNotes.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Credit note not found.'
            });
            return;
        }
        DMS_Credit_Note__c creditNote = creditNotes[0];
        if (creditNote.Status__c == 'Posted') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'message' => 'Credit note has already been posted.',
                'status' => creditNote.Status__c
            });
            return;
        }
        String approvalStatus = getApprovalStatuses(new Set<Id>{creditNote.Id}).get(creditNote.Id);
        if (creditNote.Status__c != 'Approved' && approvalStatus != 'Approved') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only approved credit notes can be posted.'
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Status__c, Invoice_Total__c, Credited_Amount__c,
                   Amount_Paid__c
            FROM DMS_Invoice__c
            WHERE Id = :creditNote.Invoice__c
              AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()
            || !new Set<String>{'Posted', 'Partially Credited'}.contains(invoices[0].Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The original posted invoice could not be found.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoices[0];
        Decimal credited = invoice.Credited_Amount__c == null ? 0 : invoice.Credited_Amount__c;
        Decimal amount = creditNote.Total_Credit_Amount__c == null
            ? 0
            : creditNote.Total_Credit_Amount__c;
        Decimal paid = invoice.Amount_Paid__c == null ? 0 : invoice.Amount_Paid__c;
        if (amount <= 0 || credited + paid + amount > invoice.Invoice_Total__c) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Posting this credit note would exceed the invoice balance remaining after payments.'
            });
            return;
        }
        invoice.Credited_Amount__c = credited + amount;
        invoice.Balance_Due__c = Math.max(
            0,
            invoice.Invoice_Total__c - invoice.Credited_Amount__c - paid
        );
        invoice.Status__c = invoice.Credited_Amount__c >= invoice.Invoice_Total__c
            ? 'Credited'
            : 'Partially Credited';
        creditNote.Status__c = 'Posted';
        creditNote.Posted_Date__c = System.now();
        update invoice;
        update creditNote;
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => 'Approved credit note posted against the invoice balance.',
            'status' => creditNote.Status__c
        });
    }

    private static List<String> getApprovalErrors(Approval.ProcessResult result) {
        List<String> messages = new List<String>();
        for (Database.Error error : result.getErrors()) {
            messages.add(error.getMessage());
        }
        return messages;
    }

    private static List<String> submitForApproval(Id recordId, Id submitterId, String comments) {
        List<String> messages = new List<String>();
        Approval.ProcessSubmitRequest approvalRequest = new Approval.ProcessSubmitRequest();
        approvalRequest.setObjectId(recordId);
        approvalRequest.setSubmitterId(String.valueOf(submitterId));
        approvalRequest.setComments(comments);
        Approval.ProcessResult result = Approval.process(approvalRequest);
        if (result.isSuccess()) return messages;
        if (result.getErrors().isEmpty()) {
            messages.add('No matching active Salesforce approval process is configured.');
            return messages;
        }
        return getApprovalErrors(result);
    }

    private static Map<Id, String> getApprovalStatuses(Set<Id> recordIds) {
        Map<Id, String> statuses = new Map<Id, String>();
        if (recordIds == null || recordIds.isEmpty()) return statuses;
        for (ProcessInstance instance : [
            SELECT TargetObjectId, Status, CreatedDate
            FROM ProcessInstance
            WHERE TargetObjectId IN :recordIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!statuses.containsKey(instance.TargetObjectId)) {
                statuses.put(instance.TargetObjectId, instance.Status);
            }
        }
        return statuses;
    }

    private static String effectiveApprovalStatus(String recordStatus, String approvalStatus) {
        if (recordStatus == 'Posted' || recordStatus == 'Processed'
            || recordStatus == 'Cancelled') return recordStatus;
        if (approvalStatus == 'Pending') return 'Submitted';
        if (approvalStatus == 'Approved' || approvalStatus == 'Rejected') return approvalStatus;
        return recordStatus;
    }

    private static Map<Id, Decimal> getDeliveredQuantitiesByOrderItem(Id invoiceId) {
        Set<String> deliveredStatuses = new Set<String>{
            'Partially Delivered', 'Delivered'
        };
        Map<Id, Decimal> deliveredByOrderItem = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c dispatchLine : [
            SELECT Order_Line_Item__c, Quantity_Delivered__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__r.Invoice__c = :invoiceId
              AND Dispatch__r.Status__c IN :deliveredStatuses
        ]) {
            if (dispatchLine.Order_Line_Item__c == null
                || dispatchLine.Quantity_Delivered__c == null
                || dispatchLine.Quantity_Delivered__c <= 0) continue;
            Decimal currentQuantity = deliveredByOrderItem.containsKey(
                dispatchLine.Order_Line_Item__c
            ) ? deliveredByOrderItem.get(dispatchLine.Order_Line_Item__c) : 0;
            deliveredByOrderItem.put(
                dispatchLine.Order_Line_Item__c,
                currentQuantity + dispatchLine.Quantity_Delivered__c
            );
        }
        return deliveredByOrderItem;
    }

    private static void validateReturnBarcode(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id invoiceId = parseId(payload.get('invoiceId'));
        String barcode = stringValue(payload.get('barcode'));
        Decimal proposedQuantity = decimalValue(payload.get('proposedQuantity'));
        if (invoiceId == null || String.isBlank(barcode) || barcode.length() > 50
            || proposedQuantity == null || proposedQuantity <= 0
            || proposedQuantity != proposedQuantity.setScale(0, RoundingMode.DOWN)) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid invoice, barcode, and whole-unit scan quantity are required.'
            });
            return;
        }

        List<DMS_Invoice__c> invoices = [
            SELECT Id, Status__c, Stock_Deduction_Status__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (invoices.isEmpty()
            || !new Set<String>{ 'Posted', 'Partially Credited' }
                .contains(invoices[0].Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Returns can only be verified against a posted invoice belonging to this distributor.'
            });
            return;
        }

        List<Product2> products = [
            SELECT Id, Name, IsActive, SFA_Product__c, QuantityUnitOfMeasure
            FROM Product2
            WHERE Barcode__c = :barcode
            LIMIT 2
        ];
        if (products.isEmpty() || products.size() > 1
            || !products[0].IsActive || products[0].SFA_Product__c != true) {
            writeResponse(response, products.isEmpty() ? 404 : 409, new Map<String, Object>{
                'success' => false,
                'message' => products.isEmpty()
                    ? 'No active product matches this barcode.'
                    : 'This barcode does not identify one active DMS product.'
            });
            return;
        }

        List<DMS_Invoice_Line__c> invoiceLines = [
            SELECT Id, Order_Line_Item__c, Product__c, Product__r.Name,
                   Quantity__c, Unit_of_Measure__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoiceId AND Product__c = :products[0].Id
        ];
        if (invoiceLines.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => products[0].Name + ' is not on the selected invoice.'
            });
            return;
        }
        if (invoiceLines.size() > 1) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'This product has multiple invoice lines. Verify the correct line manually.'
            });
            return;
        }
        DMS_Invoice_Line__c invoiceLine = invoiceLines[0];
        if (invoiceLine.Quantity__c == null || invoiceLine.Quantity__c <= 0
            || invoiceLine.Order_Line_Item__c == null) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice line is missing a valid order line or quantity.'
            });
            return;
        }
        String productUnit = products[0].QuantityUnitOfMeasure == null
            ? ''
            : products[0].QuantityUnitOfMeasure.trim().toLowerCase();
        String invoiceUnit = invoiceLine.Unit_of_Measure__c == null
            ? ''
            : invoiceLine.Unit_of_Measure__c.trim().toLowerCase();
        if (String.isBlank(productUnit) || productUnit != invoiceUnit) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The barcode packaging unit does not match the invoice line unit. Enter the return quantity manually.'
            });
            return;
        }

        Boolean legacyStockDeducted =
            invoices[0].Stock_Deduction_Status__c == 'Already Deducted (Legacy)';
        if (!legacyStockDeducted
            && String.isBlank(invoices[0].Stock_Deduction_Status__c)) {
            legacyStockDeducted = [
                SELECT COUNT()
                FROM Inventory_Transaction__c
                WHERE DMS_Invoice__c = :invoiceId
                  AND Transaction_Type__c = 'Secondary Order Sale'
            ] > 0;
        }
        Map<Id, Decimal> deliveredByOrderItem = legacyStockDeducted
            ? new Map<Id, Decimal>()
            : getDeliveredQuantitiesByOrderItem(invoiceId);
        Decimal delivered = legacyStockDeducted
            ? invoiceLine.Quantity__c
            : (deliveredByOrderItem.containsKey(invoiceLine.Order_Line_Item__c)
                ? deliveredByOrderItem.get(invoiceLine.Order_Line_Item__c)
                : 0);

        Decimal previouslyRequested = 0;
        for (Return_Item__c previousItem : [
            SELECT Quantity__c, Return_Request__r.Status__c
            FROM Return_Item__c
            WHERE Return_Request__r.DMS_Invoice__c = :invoiceId
              AND DMS_Invoice_Line__c = :invoiceLine.Id
        ]) {
            if (previousItem.Return_Request__r.Status__c == 'Cancelled'
                || previousItem.Return_Request__r.Status__c == 'Rejected') continue;
            previouslyRequested += previousItem.Quantity__c == null
                ? 0
                : previousItem.Quantity__c;
        }
        Decimal remaining = Math.max(0, delivered - previouslyRequested);
        if (proposedQuantity > remaining) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The scanned quantity exceeds the delivered quantity still eligible for return.'
            });
            return;
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'productId' => products[0].Id,
            'invoiceLineId' => invoiceLine.Id,
            'remainingQuantity' => remaining,
            'inventoryChanged' => false
        });
    }

    private static void createReturn(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id invoiceId = parseId(payload.get('invoiceId'));
        String reason = stringValue(payload.get('reason'));
        String remarks = stringValue(payload.get('remarks'));
        List<Object> requestedLines = payload.get('lines') instanceof List<Object>
            ? (List<Object>) payload.get('lines')
            : new List<Object>();
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || invoiceId == null || String.isBlank(reason) || requestedLines.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A request key, posted invoice, return reason, and at least one return line are required.'
            });
            return;
        }
        if (!new Set<String>{
            'Damaged', 'Expired', 'Near Expiry', 'Wrong Product',
            'Excess Stock', 'Quality Issue', 'Customer Return', 'Other'
        }.contains(reason)) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Select a supported sales-return reason.'
            });
            return;
        }
        List<Return_Request__c> duplicates = [
            SELECT Id, Name, Status__c
            FROM Return_Request__c
            WHERE Request_Key__c = :requestKey AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (!duplicates.isEmpty()) {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'returnRequest' => new Map<String, Object>{
                    'id' => duplicates[0].Id,
                    'number' => duplicates[0].Name,
                    'status' => duplicates[0].Status__c
                }
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Retailer__c, Warehouse__c, Status__c,
                   Stock_Deduction_Status__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()
            || !new Set<String>{'Posted', 'Partially Credited'}.contains(invoices[0].Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Returns can only be requested against a posted invoice belonging to your distributor.'
            });
            return;
        }

        Set<Id> lineIds = new Set<Id>();
        Map<Id, Decimal> requestedQuantityByLine = new Map<Id, Decimal>();
        for (Object rawLine : requestedLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each return line must contain an invoice line and positive quantity.'
                });
                return;
            }
            Map<String, Object> lineData = (Map<String, Object>) rawLine;
            Id lineId = parseId(lineData.get('invoiceLineId'));
            Decimal quantity = decimalValue(lineData.get('quantity'));
            if (lineId == null || quantity == null || quantity <= 0
                || requestedQuantityByLine.containsKey(lineId)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each return line must contain a unique invoice line and positive quantity.'
                });
                return;
            }
            lineIds.add(lineId);
            requestedQuantityByLine.put(lineId, quantity);
        }
        List<DMS_Invoice_Line__c> invoiceLines = [
            SELECT Id, Order_Line_Item__c, Product__c, Quantity__c, Unit_Price__c
            FROM DMS_Invoice_Line__c
            WHERE Id IN :lineIds AND Invoice__c = :invoiceId
            FOR UPDATE
        ];
        if (invoiceLines.size() != lineIds.size()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'One or more return lines do not belong to the selected invoice.'
            });
            return;
        }
        Map<Id, Decimal> activeReturnQuantityByLine = new Map<Id, Decimal>();
        for (Return_Item__c previousItem : [
            SELECT DMS_Invoice_Line__c, Quantity__c, Return_Request__r.Status__c
            FROM Return_Item__c
            WHERE Return_Request__r.DMS_Invoice__c = :invoiceId
              AND DMS_Invoice_Line__c IN :lineIds
        ]) {
            if (previousItem.Return_Request__r.Status__c == 'Cancelled'
                || previousItem.Return_Request__r.Status__c == 'Rejected') continue;
            Decimal currentQuantity = activeReturnQuantityByLine.containsKey(
                previousItem.DMS_Invoice_Line__c
            ) ? activeReturnQuantityByLine.get(previousItem.DMS_Invoice_Line__c) : 0;
            activeReturnQuantityByLine.put(
                previousItem.DMS_Invoice_Line__c,
                currentQuantity + previousItem.Quantity__c
            );
        }
        Boolean legacyStockDeducted =
            invoices[0].Stock_Deduction_Status__c == 'Already Deducted (Legacy)';
        if (!legacyStockDeducted
            && String.isBlank(invoices[0].Stock_Deduction_Status__c)) {
            legacyStockDeducted = [
                SELECT COUNT()
                FROM Inventory_Transaction__c
                WHERE DMS_Invoice__c = :invoiceId
                  AND Transaction_Type__c = 'Secondary Order Sale'
            ] > 0;
        }
        Map<Id, Decimal> deliveredQuantityByOrderItem =
            legacyStockDeducted
                ? new Map<Id, Decimal>()
                : getDeliveredQuantitiesByOrderItem(invoiceId);
        for (DMS_Invoice_Line__c invoiceLine : invoiceLines) {
            Decimal alreadyReturned = activeReturnQuantityByLine.containsKey(invoiceLine.Id)
                ? activeReturnQuantityByLine.get(invoiceLine.Id)
                : 0;
            Decimal deliveredQuantity = legacyStockDeducted
                ? invoiceLine.Quantity__c
                : (deliveredQuantityByOrderItem.containsKey(invoiceLine.Order_Line_Item__c)
                    ? deliveredQuantityByOrderItem.get(invoiceLine.Order_Line_Item__c)
                    : 0);
            if (alreadyReturned + requestedQuantityByLine.get(invoiceLine.Id) > deliveredQuantity) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'A requested return quantity exceeds the remaining delivered quantity.'
                });
                return;
            }
        }
        Return_Request__c returnRequest = new Return_Request__c(
            OwnerId = distributor.OwnerId,
            Outlet__c = invoices[0].Retailer__c,
            Return_Reason__c = reason,
            Status__c = 'Draft',
            Remarks__c = remarks,
            Return_Date__c = System.now(),
            Distributor__c = distributor.Id,
            Warehouse__c = invoices[0].Warehouse__c,
            DMS_Invoice__c = invoiceId,
            Approver__c = getConfiguredApprovalUserId(),
            Request_Key__c = requestKey
        );
        Decimal totalReturnAmount = 0;
        insert returnRequest;
        List<Return_Item__c> returnItems = new List<Return_Item__c>();
        for (DMS_Invoice_Line__c invoiceLine : invoiceLines) {
            Decimal quantity = requestedQuantityByLine.get(invoiceLine.Id);
            Decimal returnAmount = (invoiceLine.Unit_Price__c * quantity).setScale(2);
            totalReturnAmount += returnAmount;
            returnItems.add(new Return_Item__c(
                Return_Request__c = returnRequest.Id,
                Product__c = invoiceLine.Product__c,
                Quantity__c = quantity,
                Unit_Price__c = invoiceLine.Unit_Price__c,
                Return_Amount__c = returnAmount,
                DMS_Invoice_Line__c = invoiceLine.Id,
                Reason__c = returnItemReason(reason),
                Accepted_Quantity__c = 0,
                Rejected_Quantity__c = 0,
                Restock_Decision__c = 'Pending'
            ));
        }
        insert returnItems;
        returnRequest.Total_Amount__c = totalReturnAmount.setScale(2);
        update returnRequest;
        writeResponse(response, 201, new Map<String, Object>{
            'success' => true,
            'returnRequest' => new Map<String, Object>{
                'id' => returnRequest.Id,
                'number' => returnRequest.Name,
                'status' => returnRequest.Status__c
            }
        });
    }

    private static void submitReturn(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id returnId = parseId(payload.get('returnId'));
        if (returnId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid returnId is required.'
            });
            return;
        }
        List<Return_Request__c> returnRequests = [
            SELECT Id, Status__c, Approver__c
            FROM Return_Request__c
            WHERE Id = :returnId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (returnRequests.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Return request not found.'
            });
            return;
        }
        String currentApprovalStatus =
            getApprovalStatuses(new Set<Id>{returnRequests[0].Id}).get(returnRequests[0].Id);
        if (currentApprovalStatus == 'Pending' || currentApprovalStatus == 'Approved') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => currentApprovalStatus == 'Approved' ? 'Approved' : 'Submitted'
            });
            return;
        }
        if (returnRequests[0].Status__c != 'Draft') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only draft returns can be submitted.'
            });
            return;
        }
        Id approverId = getConfiguredApprovalUserId();
        if (approverId == null) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The configured active Salesforce approver could not be found.'
            });
            return;
        }
        if (returnRequests[0].Approver__c != approverId) {
            returnRequests[0].Approver__c = approverId;
            update returnRequests[0];
        }
        List<String> approvalErrors = submitForApproval(
            returnRequests[0].Id,
            distributor.OwnerId,
            'Sales return submitted from the DMS distributor portal.'
        );
        if (!approvalErrors.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Salesforce approval submission failed: ' +
                    String.join(approvalErrors, ' ')
            });
            return;
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'status' => 'Submitted'
        });
    }

    private static void inspectReturn(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id returnId = parseId(payload.get('returnId'));
        List<Object> inspections = payload.get('lines') instanceof List<Object>
            ? (List<Object>) payload.get('lines')
            : new List<Object>();
        if (returnId == null || inspections.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A return request and inspection results are required.'
            });
            return;
        }
        List<Return_Request__c> requests = [
            SELECT Id, Status__c
            FROM Return_Request__c
            WHERE Id = :returnId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        String approvalStatus = requests.isEmpty()
            ? null
            : getApprovalStatuses(new Set<Id>{requests[0].Id}).get(requests[0].Id);
        if (requests.isEmpty()
            || (requests[0].Status__c != 'Approved' && approvalStatus != 'Approved')) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only an approved or received return can be inspected.'
            });
            return;
        }
        Set<Id> itemIds = new Set<Id>();
        Map<Id, Map<String, Object>> inspectionById = new Map<Id, Map<String, Object>>();
        for (Object rawLine : inspections) {
            if (!(rawLine instanceof Map<String, Object>)) continue;
            Map<String, Object> inspection = (Map<String, Object>) rawLine;
            Id itemId = parseId(inspection.get('returnItemId'));
            if (itemId == null || inspectionById.containsKey(itemId)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each inspection must identify a unique return item.'
                });
                return;
            }
            itemIds.add(itemId);
            inspectionById.put(itemId, inspection);
        }
        List<Return_Item__c> returnItems = [
            SELECT Id, Quantity__c
            FROM Return_Item__c
            WHERE Id IN :itemIds AND Return_Request__c = :returnId
            FOR UPDATE
        ];
        if (returnItems.size() != itemIds.size()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'One or more inspection items do not belong to this return.'
            });
            return;
        }
        for (Return_Item__c item : returnItems) {
            Map<String, Object> inspection = inspectionById.get(item.Id);
            Decimal accepted = decimalValue(inspection.get('acceptedQuantity'));
            Decimal rejected = decimalValue(inspection.get('rejectedQuantity'));
            String condition = stringValue(inspection.get('condition'));
            Boolean canRestock = condition == 'Good';
            String restockDecision = stringValue(inspection.get('restockDecision'));
            if (accepted == null || rejected == null || accepted < 0 || rejected < 0
                || accepted + rejected != item.Quantity__c
                || (accepted > 0 && canRestock
                    && restockDecision != 'Restock' && restockDecision != 'Do Not Restock')
                || (accepted > 0 && !canRestock && restockDecision == 'Restock')) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Inspection quantities must equal the requested quantity; damaged, expired, and defective goods cannot be restocked.'
                });
                return;
            }
            item.Accepted_Quantity__c = accepted;
            item.Rejected_Quantity__c = rejected;
            item.Condition__c = condition;
            item.Restock_Decision__c = accepted == 0 || !canRestock
                ? 'Do Not Restock'
                : restockDecision;
        }
        update returnItems;
        requests[0].Status__c = 'Approved';
        update requests[0];
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'status' => requests[0].Status__c
        });
    }

    private static void completeReturn(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id returnId = parseId(payload.get('returnId'));
        if (returnId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid returnId is required.'
            });
            return;
        }
        List<Return_Request__c> requests = [
            SELECT Id, Name, Status__c, Warehouse__c, DMS_Invoice__c
            FROM Return_Request__c
            WHERE Id = :returnId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (requests.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Return request not found.'
            });
            return;
        }
        Return_Request__c returnRequest = requests[0];
        if (returnRequest.Status__c == 'Processed') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'message' => 'Return has already been processed.',
                'status' => returnRequest.Status__c
            });
            return;
        }
        if (returnRequest.Status__c != 'Approved') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Only inspected returns can be completed.'
            });
            return;
        }
        List<Return_Item__c> returnItems = [
            SELECT Id, Product__c, Quantity__c, Accepted_Quantity__c,
                   Rejected_Quantity__c, Condition__c, Restock_Decision__c,
                   Product_Batch__c, DMS_Invoice_Line__c
            FROM Return_Item__c
            WHERE Return_Request__c = :returnRequest.Id
            FOR UPDATE
        ];
        if (returnItems.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The return has no inspected line items.'
            });
            return;
        }
        Set<Id> invoiceLineIds = new Set<Id>();
        for (Return_Item__c item : returnItems) {
            if (item.DMS_Invoice_Line__c != null) invoiceLineIds.add(item.DMS_Invoice_Line__c);
            Decimal accepted = item.Accepted_Quantity__c == null ? 0 : item.Accepted_Quantity__c;
            Decimal rejected = item.Rejected_Quantity__c == null ? 0 : item.Rejected_Quantity__c;
            if (item.Condition__c == null || accepted + rejected != item.Quantity__c) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Every return line must be inspected before completion.'
                });
                return;
            }
        }
        List<DMS_Invoice__c> originalInvoices = [
            SELECT Id, Stock_Deduction_Status__c
            FROM DMS_Invoice__c
            WHERE Id = :returnRequest.DMS_Invoice__c
              AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (originalInvoices.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The return no longer references an invoice belonging to this distributor.'
            });
            return;
        }
        Map<Id, Decimal> soldQuantityByLine = new Map<Id, Decimal>();
        Map<Id, Id> orderItemByInvoiceLine = new Map<Id, Id>();
        for (DMS_Invoice_Line__c originalLine : [
            SELECT Id, Order_Line_Item__c, Quantity__c
            FROM DMS_Invoice_Line__c
            WHERE Id IN :invoiceLineIds AND Invoice__c = :returnRequest.DMS_Invoice__c
        ]) {
            soldQuantityByLine.put(originalLine.Id, originalLine.Quantity__c);
            orderItemByInvoiceLine.put(originalLine.Id, originalLine.Order_Line_Item__c);
        }
        Boolean legacyStockDeducted =
            originalInvoices[0].Stock_Deduction_Status__c == 'Already Deducted (Legacy)';
        if (!legacyStockDeducted
            && String.isBlank(originalInvoices[0].Stock_Deduction_Status__c)) {
            legacyStockDeducted = [
                SELECT COUNT()
                FROM Inventory_Transaction__c
                WHERE DMS_Invoice__c = :returnRequest.DMS_Invoice__c
                  AND Transaction_Type__c = 'Secondary Order Sale'
            ] > 0;
        }
        Map<Id, Decimal> deliveredQuantityByOrderItem =
            legacyStockDeducted
                ? new Map<Id, Decimal>()
                : getDeliveredQuantitiesByOrderItem(returnRequest.DMS_Invoice__c);
        Map<Id, Decimal> previouslyReturnedByLine = new Map<Id, Decimal>();
        for (Return_Item__c completedItem : [
            SELECT DMS_Invoice_Line__c, Quantity__c
            FROM Return_Item__c
            WHERE Return_Request__r.DMS_Invoice__c = :returnRequest.DMS_Invoice__c
              AND Return_Request__r.Status__c = 'Processed'
              AND DMS_Invoice_Line__c IN :invoiceLineIds
        ]) {
            Decimal priorQuantity = previouslyReturnedByLine.containsKey(
                completedItem.DMS_Invoice_Line__c
            ) ? previouslyReturnedByLine.get(completedItem.DMS_Invoice_Line__c) : 0;
            previouslyReturnedByLine.put(
                completedItem.DMS_Invoice_Line__c,
                priorQuantity + completedItem.Quantity__c
            );
        }
        for (Return_Item__c item : returnItems) {
            Decimal alreadyReturned = previouslyReturnedByLine.containsKey(item.DMS_Invoice_Line__c)
                ? previouslyReturnedByLine.get(item.DMS_Invoice_Line__c)
                : 0;
            Id orderItemId = orderItemByInvoiceLine.get(item.DMS_Invoice_Line__c);
            Decimal deliveredQuantity = legacyStockDeducted
                ? soldQuantityByLine.get(item.DMS_Invoice_Line__c)
                : (deliveredQuantityByOrderItem.containsKey(orderItemId)
                    ? deliveredQuantityByOrderItem.get(orderItemId)
                    : 0);
            if (!soldQuantityByLine.containsKey(item.DMS_Invoice_Line__c)
                || alreadyReturned + item.Quantity__c > deliveredQuantity) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Cumulative completed returns cannot exceed the delivered invoice quantity.'
                });
                return;
            }
        }
        Set<Id> productIds = new Set<Id>();
        for (Return_Item__c item : returnItems) {
            if (item.Product__c != null) productIds.add(item.Product__c);
        }
        List<Inventory__c> inventoryRecords = [
            SELECT Id, Product__c, Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :returnRequest.Warehouse__c
              AND Product__c IN :productIds
            FOR UPDATE
        ];
        Map<Id, Inventory__c> inventoryByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c stock : inventoryRecords) {
            if (inventoryByProduct.containsKey(stock.Product__c)) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Duplicate inventory balances exist for a product and warehouse.'
                });
                return;
            }
            inventoryByProduct.put(stock.Product__c, stock);
        }
        List<Inventory_Transaction__c> transactions = new List<Inventory_Transaction__c>();
        for (Return_Item__c item : returnItems) {
            Decimal accepted = item.Accepted_Quantity__c == null ? 0 : item.Accepted_Quantity__c;
            if (accepted == 0 || item.Restock_Decision__c != 'Restock') continue;
            if (item.Product_Batch__c != null) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Batch-specific return restocking is not enabled until batch balances are reconciled.'
                });
                return;
            }
            Inventory__c stock = inventoryByProduct.get(item.Product__c);
            if (stock == null) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'No inventory balance exists for a restockable return product.'
                });
                return;
            }
            Decimal currentQuantity = stock.Available_Quantity__c == null
                ? 0
                : stock.Available_Quantity__c;
            stock.Available_Quantity__c = currentQuantity + accepted;
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = stock.Id,
                Transaction_Type__c = 'Sales Return',
                Quantity__c = accepted,
                Transaction_Date__c = System.now(),
                Reference_Number__c = returnRequest.Name,
                Transaction_Description__c = 'Inspected sellable goods restocked',
                Return_Request__c = returnRequest.Id
            ));
        }
        update inventoryRecords;
        if (!transactions.isEmpty()) insert transactions;
        returnRequest.Status__c = 'Processed';
        returnRequest.Processed_Date__c = System.now();
        update returnRequest;
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => 'Return completed; eligible accepted goods were restocked.',
            'status' => returnRequest.Status__c
        });
    }

    private static Map<String, Object> invoiceSummary(DMS_Invoice__c invoice) {
        return new Map<String, Object>{
            'id' => invoice.Id,
            'number' => invoice.Name,
            'date' => invoice.Invoice_Date__c,
            'retailerId' => invoice.Retailer__c,
            'retailerName' => invoice.Retailer__r == null ? null : invoice.Retailer__r.Name,
            'customerName' => invoice.Retailer__r == null ? null : invoice.Retailer__r.Name,
            'retailerEmail' => invoice.Retailer__r == null
                ? null
                : invoice.Retailer__r.Email__c,
            'billingAddress' => invoice.Retailer__r == null ? null : new Map<String, Object>{
                'street' => invoice.Retailer__r.BillingStreet,
                'city' => invoice.Retailer__r.BillingCity,
                'state' => invoice.Retailer__r.BillingState,
                'postalCode' => invoice.Retailer__r.BillingPostalCode,
                'country' => invoice.Retailer__r.BillingCountry
            },
            'shippingAddress' => invoice.Retailer__r == null ? null : new Map<String, Object>{
                'street' => invoice.Retailer__r.ShippingStreet,
                'city' => invoice.Retailer__r.ShippingCity,
                'state' => invoice.Retailer__r.ShippingState,
                'postalCode' => invoice.Retailer__r.ShippingPostalCode,
                'country' => invoice.Retailer__r.ShippingCountry
            },
            'distributorName' => invoice.Distributor__r == null
                ? null
                : invoice.Distributor__r.Name,
            'distributorPhone' => invoice.Distributor__r == null
                ? null
                : invoice.Distributor__r.Phone,
            'distributorAddress' => invoice.Distributor__r == null ? null : new Map<String, Object>{
                'street' => invoice.Distributor__r.BillingStreet,
                'city' => invoice.Distributor__r.BillingCity,
                'state' => invoice.Distributor__r.BillingState,
                'postalCode' => invoice.Distributor__r.BillingPostalCode,
                'country' => invoice.Distributor__r.BillingCountry
            },
            'orderId' => invoice.Secondary_Order__c,
            'orderNumber' => invoice.Secondary_Order__r == null
                ? null
                : invoice.Secondary_Order__r.OrderNumber,
            'salesType' => invoice.Secondary_Order__r == null
                ? null
                : (invoice.Secondary_Order__r.Type == 'Primary Order'
                    ? 'Primary'
                    : 'Secondary'),
            'orderStatus' => invoice.Secondary_Order__r == null
                ? null
                : invoice.Secondary_Order__r.Status,
            'status' => invoice.Status__c,
            'subtotal' => invoice.Subtotal__c,
            'discount' => invoice.Total_Discount__c,
            'taxableAmount' => invoice.Taxable_Amount__c,
            'tax' => invoice.Tax_Amount__c,
            'total' => invoice.Invoice_Total__c,
            'creditedAmount' => invoice.Credited_Amount__c,
            'amountPaid' => invoice.Amount_Paid__c == null ? 0 : invoice.Amount_Paid__c,
            'balanceDue' => invoice.Balance_Due__c,
            'paymentStatus' => invoice.Balance_Due__c == null || invoice.Balance_Due__c <= 0
                ? 'Paid'
                : (invoice.Amount_Paid__c == null || invoice.Amount_Paid__c <= 0
                    ? 'Unpaid'
                    : 'Partially Paid'),
            'paymentReceipts' => new List<Map<String, Object>>(),
            'postedDate' => invoice.Posted_Date__c
        };
    }

    private static void recordPayment(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id invoiceId = parseId(payload.get('invoiceId'));
        Decimal amount = decimalValue(payload.get('amount'));
        String paymentMethod = stringValue(payload.get('paymentMethod'));
        String referenceNumber = stringValue(payload.get('referenceNumber'));
        String notes = stringValue(payload.get('notes'));
        Date receiptDate = Date.today();
        String suppliedDate = stringValue(payload.get('receiptDate'));
        if (!String.isBlank(suppliedDate)) {
            try {
                receiptDate = Date.valueOf(suppliedDate);
            } catch (Exception error) {
                receiptDate = null;
            }
        }
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || invoiceId == null || amount == null || amount <= 0
            || amount != amount.setScale(2, RoundingMode.DOWN)
            || !new Set<String>{
                'Bank Transfer', 'UPI', 'Cash', 'Cheque', 'Other'
            }.contains(paymentMethod)
            || receiptDate == null
            || (referenceNumber != null && referenceNumber.length() > 80)
            || (notes != null && notes.length() > 1000)) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Provide a valid invoice, positive payment amount, receipt date, and supported payment method. Reference and notes must fit their fields.'
            });
            return;
        }
        List<DMS_Payment_Receipt__c> duplicates = [
            SELECT Id, Name, Distributor__c, Invoice__c, Amount__c, Receipt_Date__c,
                   Payment_Method__c, Reference_Number__c, Notes__c,
                   Invoice__r.Name, Invoice__r.Amount_Paid__c, Invoice__r.Balance_Due__c
            FROM DMS_Payment_Receipt__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];
        if (!duplicates.isEmpty()) {
            DMS_Payment_Receipt__c duplicate = duplicates[0];
            if (duplicate.Distributor__c != distributor.Id
                || duplicate.Invoice__c != invoiceId
                || duplicate.Amount__c != amount
                || duplicate.Payment_Method__c != paymentMethod
                || duplicate.Reference_Number__c != referenceNumber
                || duplicate.Notes__c != notes
                || (!String.isBlank(suppliedDate)
                    && duplicate.Receipt_Date__c != receiptDate)) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'This payment request key is already associated with a different payment.'
                });
                return;
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'receipt' => new Map<String, Object>{
                    'id' => duplicate.Id,
                    'number' => duplicate.Name,
                    'invoiceNumber' => duplicate.Invoice__r.Name,
                    'amount' => duplicate.Amount__c,
                    'receiptDate' => duplicate.Receipt_Date__c,
                    'paymentMethod' => duplicate.Payment_Method__c,
                    'referenceNumber' => duplicate.Reference_Number__c,
                    'amountPaid' => duplicate.Invoice__r.Amount_Paid__c,
                    'balanceDue' => duplicate.Invoice__r.Balance_Due__c
                },
                'message' => 'This payment receipt was already recorded.'
            });
            return;
        }
        List<DMS_Invoice__c> invoiceRows = [
            SELECT Id, Name, Status__c, Invoice_Total__c, Credited_Amount__c,
                   Amount_Paid__c, Balance_Due__c, Retailer__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoiceRows.isEmpty()
            || !new Set<String>{'Posted', 'Partially Credited'}.contains(invoiceRows[0].Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Payments can only be recorded against a posted invoice belonging to your distributor.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoiceRows[0];
        Decimal paid = invoice.Amount_Paid__c == null ? 0 : invoice.Amount_Paid__c;
        Decimal credited = invoice.Credited_Amount__c == null ? 0 : invoice.Credited_Amount__c;
        Decimal invoiceTotal = invoice.Invoice_Total__c == null ? 0 : invoice.Invoice_Total__c;
        Decimal balance = Math.max(0, invoiceTotal - paid - credited);
        if (amount > balance) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The payment amount exceeds the outstanding invoice balance of ' +
                    String.valueOf(balance.setScale(2)) + '.'
            });
            return;
        }
        DMS_Payment_Receipt__c receipt = new DMS_Payment_Receipt__c(
            OwnerId = distributor.OwnerId,
            Distributor__c = distributor.Id,
            Invoice__c = invoice.Id,
            Receipt_Date__c = receiptDate,
            Amount__c = amount,
            Payment_Method__c = paymentMethod,
            Reference_Number__c = referenceNumber,
            Notes__c = notes,
            Request_Key__c = requestKey,
            Balance_After_Receipt__c = balance - amount
        );
        insert receipt;
        invoice.Amount_Paid__c = paid + amount;
        invoice.Balance_Due__c = Math.max(0, invoiceTotal - credited - invoice.Amount_Paid__c);
        update invoice;
        writeResponse(response, 201, new Map<String, Object>{
            'success' => true,
            'receipt' => new Map<String, Object>{
                'id' => receipt.Id,
                'number' => receipt.Name,
                'invoiceNumber' => invoice.Name,
                'amount' => receipt.Amount__c,
                'receiptDate' => receipt.Receipt_Date__c,
                'paymentMethod' => receipt.Payment_Method__c,
                'referenceNumber' => receipt.Reference_Number__c,
                'amountPaid' => invoice.Amount_Paid__c,
                'balanceDue' => invoice.Balance_Due__c
            },
            'message' => 'Payment received and receipt recorded.'
        });
    }

    private static void downloadReceipt(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id receiptId = parseId(payload.get('receiptId'));
        if (receiptId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid receiptId is required.'
            });
            return;
        }
        List<DMS_Payment_Receipt__c> receipts = [
            SELECT Id, Name
            FROM DMS_Payment_Receipt__c
            WHERE Id = :receiptId AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (receipts.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Payment receipt not found.'
            });
            return;
        }
        Blob pdf = renderPaymentReceiptPdf(receiptId, distributor);
        if (!hasPdfContent(pdf)) {
            writeResponse(response, 502, new Map<String, Object>{
                'success' => false,
                'message' => 'Salesforce generated an empty receipt PDF.'
            });
            return;
        }
        response.statusCode = 200;
        response.addHeader('Content-Type', 'application/pdf');
        response.addHeader(
            'Content-Disposition',
            'attachment; filename="' + receipts[0].Name + '.pdf"'
        );
        response.responseBody = pdf;
    }

    private static void emailReceipt(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id receiptId = parseId(payload.get('receiptId'));
        String recipientEmail = stringValue(payload.get('recipientEmail'));
        if (receiptId == null || String.isBlank(recipientEmail)
            || recipientEmail.length() > 254
            || !Pattern.matches(
                '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$',
                recipientEmail.toUpperCase()
            )) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid receiptId and recipient email address are required.'
            });
            return;
        }
        List<DMS_Payment_Receipt__c> receipts = [
            SELECT Id, Name, Amount__c, Receipt_Date__c, Payment_Method__c,
                   Invoice__r.Name
            FROM DMS_Payment_Receipt__c
            WHERE Id = :receiptId AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (receipts.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Payment receipt not found.'
            });
            return;
        }
        DMS_Payment_Receipt__c receipt = receipts[0];
        Blob pdf = renderPaymentReceiptPdf(receipt.Id, distributor);
        if (!hasPdfContent(pdf)) {
            writeResponse(response, 502, new Map<String, Object>{
                'success' => false,
                'message' => 'Salesforce generated an empty receipt PDF.'
            });
            return;
        }
        Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
        attachment.setFileName(receipt.Name + '.pdf');
        attachment.setContentType('application/pdf');
        attachment.setBody(pdf);

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new String[] { recipientEmail });
        email.setSubject('Payment receipt ' + receipt.Name);
        email.setPlainTextBody(
            'Attached is payment receipt ' + receipt.Name +
            ' for invoice ' + receipt.Invoice__r.Name + '.'
        );
        email.setFileAttachments(new Messaging.EmailFileAttachment[] { attachment });
        email.setSaveAsActivity(false);
        Messaging.SendEmailResult[] results = Messaging.sendEmail(
            new Messaging.SingleEmailMessage[] { email },
            false
        );
        if (results.isEmpty() || !results[0].isSuccess()) {
            String message = 'Salesforce could not send the receipt email.';
            if (!results.isEmpty() && results[0].getErrors().size() > 0) {
                message += ' ' + results[0].getErrors()[0].getMessage();
            }
            writeResponse(response, 502, new Map<String, Object>{
                'success' => false,
                'message' => message
            });
            return;
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => 'Payment receipt emailed to ' + recipientEmail + '.',
            'receiptNumber' => receipt.Name,
            'recipientEmail' => recipientEmail
        });
    }

    private static Blob renderPaymentReceiptPdf(Id receiptId, Account distributor) {
        if (Test.isRunningTest()) {
            return Blob.valueOf('%PDF-1.4\nDMS receipt test PDF');
        }
        Long expiresAt = System.now().addMinutes(2).getTime();
        String signature = receiptPdfSignature(
            receiptId,
            distributor.Id,
            expiresAt,
            distributor.DMS_Session_Token_Hash__c
        );
        PageReference pdfPage = Page.DMSPaymentReceiptPdf;
        pdfPage.getParameters().put('id', String.valueOf(receiptId));
        pdfPage.getParameters().put('distributorId', String.valueOf(distributor.Id));
        pdfPage.getParameters().put('expiresAt', String.valueOf(expiresAt));
        pdfPage.getParameters().put('signature', signature);
        return pdfPage.getContentAsPDF();
    }

    private static Boolean hasPdfContent(Blob pdf) {
        return pdf != null && pdf.size() >= 5;
    }

    private static String receiptPdfSignature(
        Id receiptId,
        Id distributorId,
        Long expiresAt,
        String sessionTokenHash
    ) {
        String signedValue = String.valueOf(receiptId) + '|' +
            String.valueOf(distributorId) + '|' + String.valueOf(expiresAt);
        return EncodingUtil.convertToHex(Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(signedValue),
            Blob.valueOf(sessionTokenHash)
        ));
    }

    private static Map<String, Object> readPayload() {
        if (RestContext.request == null || RestContext.request.requestBody == null) return null;
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
        } catch (Exception error) {
            return null;
        }
    }

    private static Id parseId(Object value) {
        if (value == null) return null;
        try {
            return (Id) String.valueOf(value);
        } catch (Exception error) {
            return null;
        }
    }

    private static Decimal decimalValue(Object value) {
        if (value == null) return null;
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception error) {
            return null;
        }
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static Id getConfiguredApprovalUserId() {
        List<User> approvers = [
            SELECT Id
            FROM User
            WHERE Name = :Label.DMS_Approval_User_Name
              AND IsActive = true
            LIMIT 2
        ];
        return approvers.size() == 1 ? approvers[0].Id : null;
    }

    private static String returnItemReason(String reason) {
        if (reason == 'Damaged') return 'Damaged Product';
        if (reason == 'Expired') return 'Expired Product';
        if (reason == 'Wrong Product') return 'Wrong Product';
        if (reason == 'Quality Issue') return 'Quality Issue';
        if (reason == 'Excess Stock') return 'Excess Stock';
        if (reason == 'Customer Return') return 'Customer Return';
        return 'Other';
    }

    private static Account findDistributor(String token) {
        if (String.isBlank(token) || token.length() != 64
            || !Pattern.matches('^[a-fA-F0-9]{64}$', token)) return null;
        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
        Datetime currentTime = System.now();
        List<Account> distributors = [
            SELECT Id, Name, OwnerId, DMS_Session_Token_Hash__c
            FROM Account
            WHERE DMS_Session_Token_Hash__c = :tokenHash
              AND DMS_Session_Expires_At__c > :currentTime
              AND Account_Category__c LIKE '%Distributor%'
              AND Active__c = 'Yes'
              AND Login_Status__c = 'Active'
            LIMIT 1
        ];
        return distributors.isEmpty() ? null : distributors[0];
    }

    private static String getSessionToken() {
        if (RestContext.request == null || RestContext.request.headers == null) return null;
        for (String headerName : RestContext.request.headers.keySet()) {
            if (headerName.equalsIgnoreCase('X-DMS-Session')) {
                String token = RestContext.request.headers.get(headerName);
                return String.isBlank(token) ? null : token.trim();
            }
        }
        return null;
    }

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> body
    ) {
        response.statusCode = statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private class RequestException extends Exception {}
}
