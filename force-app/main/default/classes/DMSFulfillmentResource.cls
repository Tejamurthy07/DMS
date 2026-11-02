@RestResource(urlMapping='/dms/v1/fulfillment/*')
global without sharing class DMSFulfillmentResource {
    private static final Integer MAX_RECORDS = 200;

    @HttpGet
    global static void getFulfillment() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        Account distributor = findDistributor(getSessionToken());
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }
        try {
            List<DMS_Invoice__c> postedInvoices = [
                SELECT Id, Name, Status__c, Stock_Deduction_Status__c,
                       Secondary_Order__c, Secondary_Order__r.OrderNumber,
                       Secondary_Order__r.Status, Secondary_Order__r.Type,
                       Warehouse__c, Warehouse__r.Name,
                       Invoice_Total__c, Invoice_Date__c, Retailer__r.Name
                FROM DMS_Invoice__c
                WHERE Distributor__c = :distributor.Id
                  AND Status__c = 'Posted'
                  AND Secondary_Order__r.Type = 'Secondary Order'
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ];
            Set<Id> invoiceIds = new Set<Id>();
            for (DMS_Invoice__c invoice : postedInvoices) invoiceIds.add(invoice.Id);

            Map<Id, Decimal> dispatchedByOrderItem = getDispatchedQuantities(
                new Set<String>{
                    'Draft', 'Submitted', 'Approved', 'Dispatched',
                    'Partially Delivered', 'Delivered'
                },
                invoiceIds
            );
            Map<Id, List<Map<String, Object>>> linesByInvoice =
                new Map<Id, List<Map<String, Object>>>();
            for (DMS_Invoice_Line__c line : [
                SELECT Id, Invoice__c, Order_Line_Item__c, Product__c, Product__r.Name,
                       Quantity__c, Unit_of_Measure__c, Unit_Price__c
                FROM DMS_Invoice_Line__c
                WHERE Invoice__c IN :invoiceIds
                ORDER BY CreatedDate, Id
            ]) {
                Decimal previouslyDispatched = dispatchedByOrderItem.containsKey(
                    line.Order_Line_Item__c
                ) ? dispatchedByOrderItem.get(line.Order_Line_Item__c) : 0;
                if (!linesByInvoice.containsKey(line.Invoice__c)) {
                    linesByInvoice.put(line.Invoice__c, new List<Map<String, Object>>());
                }
                linesByInvoice.get(line.Invoice__c).add(new Map<String, Object>{
                    'invoiceLineId' => line.Id,
                    'orderItemId' => line.Order_Line_Item__c,
                    'productId' => line.Product__c,
                    'productName' => line.Product__r == null ? null : line.Product__r.Name,
                    'quantity' => line.Quantity__c,
                    'previouslyDispatched' => previouslyDispatched,
                    'remainingQuantity' => Math.max(0, line.Quantity__c - previouslyDispatched),
                    'unitOfMeasure' => line.Unit_of_Measure__c,
                    'unitPrice' => line.Unit_Price__c
                });
            }

            List<Map<String, Object>> invoiceSummaries = new List<Map<String, Object>>();
            for (DMS_Invoice__c invoice : postedInvoices) {
                List<Map<String, Object>> lines = linesByInvoice.containsKey(invoice.Id)
                    ? linesByInvoice.get(invoice.Id)
                    : new List<Map<String, Object>>();
                Boolean hasRemaining = false;
                for (Map<String, Object> line : lines) {
                    if ((Decimal) line.get('remainingQuantity') > 0) hasRemaining = true;
                }
                if (hasRemaining && !lines.isEmpty()) {
                    invoiceSummaries.add(new Map<String, Object>{
                        'id' => invoice.Id,
                        'number' => invoice.Name,
                        'date' => invoice.Invoice_Date__c,
                        'total' => invoice.Invoice_Total__c,
                        'orderId' => invoice.Secondary_Order__c,
                        'orderNumber' => invoice.Secondary_Order__r == null
                            ? null
                            : invoice.Secondary_Order__r.OrderNumber,
                        'orderStatus' => invoice.Secondary_Order__r == null
                            ? null
                            : invoice.Secondary_Order__r.Status,
                        'orderType' => invoice.Secondary_Order__r == null
                            ? null
                            : invoice.Secondary_Order__r.Type,
                        'retailerName' => invoice.Retailer__r == null
                            ? null
                            : invoice.Retailer__r.Name,
                        'warehouseId' => invoice.Warehouse__c,
                        'warehouseName' => invoice.Warehouse__r == null
                            ? null
                            : invoice.Warehouse__r.Name,
                        'stockDeductionStatus' => invoice.Stock_Deduction_Status__c,
                        'isLegacyDeducted' => invoice.Stock_Deduction_Status__c
                            == 'Already Deducted (Legacy)',
                        'lines' => lines
                    });
                }
            }

            List<DMS_Dispatch__c> dispatchRecords = [
                SELECT Id, Name, Invoice__c, Invoice__r.Name, Order__c,
                       Order__r.OrderNumber, Order__r.Type, Warehouse__r.Name, Status__c,
                       Delivery_Status__c, Dispatch_Date__c, Expected_Delivery_Date__c,
                       Actual_Dispatch_Date__c, Actual_Delivery_Date__c,
                       Transporter_Name__c, Vehicle_Number__c, Tracking_Number__c,
                       Recipient_Name__c, Delivery_Remarks__c
                FROM DMS_Dispatch__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RECORDS
            ];
            Set<Id> dispatchIds = new Set<Id>();
            for (DMS_Dispatch__c dispatch : dispatchRecords) dispatchIds.add(dispatch.Id);
            Map<Id, String> approvalStatuses = getApprovalStatuses(dispatchIds);
            Map<Id, Map<String, Object>> dispatchById =
                new Map<Id, Map<String, Object>>();
            List<Map<String, Object>> dispatches = new List<Map<String, Object>>();
            for (DMS_Dispatch__c dispatch : dispatchRecords) {
                Map<String, Object> summary = dispatchSummary(
                    dispatch,
                    approvalStatuses.get(dispatch.Id)
                );
                summary.put('lines', new List<Map<String, Object>>());
                dispatches.add(summary);
                dispatchById.put(dispatch.Id, summary);
            }
            for (DMS_Dispatch_Line__c line : [
                SELECT Id, Dispatch__c, Order_Line_Item__c, Product__c,
                       Product_Name_Snapshot__c, Quantity__c, Quantity_Delivered__c,
                       Quantity_Short__c, Quantity_Damaged__c, Unit_of_Measure__c,
                       Order_Line_Item__r.Paid_Quantity__c,
                       Order_Line_Item__r.Free_Quantity__c
                FROM DMS_Dispatch_Line__c
                WHERE Dispatch__c IN :dispatchIds
                ORDER BY CreatedDate, Id
            ]) {
                List<Map<String, Object>> lines =
                    (List<Map<String, Object>>) dispatchById.get(line.Dispatch__c).get('lines');
                lines.add(new Map<String, Object>{
                    'id' => line.Id,
                    'orderItemId' => line.Order_Line_Item__c,
                    'productId' => line.Product__c,
                    'productName' => line.Product_Name_Snapshot__c,
                    'lineType' => getDispatchLineType(
                        line.Order_Line_Item__r == null
                            ? null
                            : line.Order_Line_Item__r.Paid_Quantity__c,
                        line.Order_Line_Item__r == null
                            ? null
                            : line.Order_Line_Item__r.Free_Quantity__c
                    ),
                    'paidQuantity' => line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Paid_Quantity__c,
                    'freeQuantity' => line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Free_Quantity__c,
                    'quantity' => line.Quantity__c,
                    'deliveredQuantity' => line.Quantity_Delivered__c,
                    'acceptedQuantity' => (line.Quantity_Delivered__c == null
                        ? 0
                        : line.Quantity_Delivered__c) -
                        (line.Quantity_Damaged__c == null
                            ? 0
                            : line.Quantity_Damaged__c),
                    'shortQuantity' => line.Quantity_Short__c,
                    'damagedQuantity' => line.Quantity_Damaged__c,
                    'unitOfMeasure' => line.Unit_of_Measure__c
                });
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'eligibleInvoices' => invoiceSummaries,
                'dispatches' => dispatches,
                'report' => new Map<String, Object>{
                    'eligibleDispatchCount' => invoiceSummaries.size(),
                    'dispatchCount' => dispatchRecords.size(),
                    'inTransitCount' => countDispatches(dispatchRecords, approvalStatuses, 'Dispatched'),
                    'deliveryExceptionCount' => countDeliveryExceptions(dispatchRecords)
                }
            });
        } catch (Exception error) {
            System.debug(LoggingLevel.ERROR,
                'DMS fulfillment data load failed: ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'Fulfillment data could not be loaded. Please try again.'
            });
        }
    }

    @HttpPost
    global static void postFulfillmentAction() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        Account distributor = findDistributor(getSessionToken());
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }
        Savepoint savepoint = Database.setSavepoint();
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
            if (action == 'validateDispatchBarcode') {
                validateDispatchBarcode(distributor, payload, response);
            } else if (action == 'createDispatch') {
                createDispatch(distributor, payload, response);
            } else if (action == 'submitDispatch') {
                submitDispatch(distributor, payload, response);
            } else if (action == 'confirmDispatch') {
                confirmDispatch(distributor, payload, response);
            } else if (action == 'recordDelivery') {
                recordDelivery(distributor, payload, response);
            } else {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The requested fulfillment action is not supported.'
                });
            }
        } catch (DmlException error) {
            Database.rollback(savepoint);
            String message = error.getNumDml() > 0 ? error.getDmlMessage(0) : error.getMessage();
            System.debug(LoggingLevel.ERROR,
                'DMS fulfillment operation failed: ' + message + '\n' +
                error.getStackTraceString());
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'The fulfillment operation failed: ' + message
            });
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR,
                'DMS fulfillment operation failed: ' + error.getMessage() + '\n' +
                error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The fulfillment operation failed. Please try again.'
            });
        }
    }

    private static void validateDispatchBarcode(
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
            SELECT Id, Status__c, Stock_Deduction_Status__c,
                   Secondary_Order__c, Secondary_Order__r.Type,
                   Secondary_Order__r.Status, Warehouse__c,
                   Warehouse__r.Distributor__c, Warehouse__r.Warehouse_Type__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (invoices.isEmpty() || invoices[0].Status__c != 'Posted'
            || invoices[0].Secondary_Order__r == null
            || invoices[0].Secondary_Order__r.Type != 'Secondary Order'
            || invoices[0].Secondary_Order__r.Status != 'Activated'
            || invoices[0].Warehouse__r == null
            || invoices[0].Warehouse__r.Distributor__c != distributor.Id
            || invoices[0].Warehouse__r.Warehouse_Type__c != 'Distributor Warehouse') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The selected invoice is not an eligible secondary-dispatch transaction.'
            });
            return;
        }
        Boolean eligibleStockStatus = new Set<String>{
            'Pending Dispatch', 'Partially Dispatched', 'Already Deducted (Legacy)'
        }.contains(invoices[0].Stock_Deduction_Status__c);
        if (String.isBlank(invoices[0].Stock_Deduction_Status__c)) {
            eligibleStockStatus = [
                SELECT COUNT()
                FROM Inventory_Transaction__c
                WHERE DMS_Invoice__c = :invoiceId
                  AND Transaction_Type__c = 'Secondary Order Sale'
            ] > 0;
        }
        if (!eligibleStockStatus) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice is not eligible for dispatch verification.'
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
                    : 'This barcode does not identify one active product.'
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
                'message' => 'This product has multiple invoice lines. Select and verify its line manually.'
            });
            return;
        }
        DMS_Invoice_Line__c invoiceLine = invoiceLines[0];
        if (invoiceLine.Order_Line_Item__c == null
            || invoiceLine.Quantity__c == null || invoiceLine.Quantity__c <= 0) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice line is missing a valid order line or quantity.'
            });
            return;
        }
        String productUnit = products[0].QuantityUnitOfMeasure == null
            ? ''
            : products[0].QuantityUnitOfMeasure.trim().toLowerCase();
        String lineUnit = invoiceLine.Unit_of_Measure__c == null
            ? ''
            : invoiceLine.Unit_of_Measure__c.trim().toLowerCase();
        if (String.isBlank(productUnit) || productUnit != lineUnit) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The barcode packaging unit does not match the invoice line unit. Enter the dispatch quantity manually.'
            });
            return;
        }

        Map<Id, Decimal> dispatched = getDispatchedQuantities(
            new Set<String>{
                'Draft', 'Submitted', 'Approved', 'Dispatched',
                'Partially Delivered', 'Delivered'
            },
            new Set<Id>{ invoiceId }
        );
        Decimal previous = dispatched.containsKey(invoiceLine.Order_Line_Item__c)
            ? dispatched.get(invoiceLine.Order_Line_Item__c)
            : 0;
        Decimal remaining = Math.max(0, invoiceLine.Quantity__c - previous);
        if (proposedQuantity > remaining) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The scanned quantity exceeds the remaining invoice quantity.'
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

    private static void createDispatch(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id invoiceId = parseId(payload.get('invoiceId'));
        List<Object> requestedLines = payload.get('lines') instanceof List<Object>
            ? (List<Object>) payload.get('lines')
            : new List<Object>();
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || invoiceId == null || requestedLines.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A request key, posted invoice, and at least one dispatch line are required.'
            });
            return;
        }
        List<DMS_Dispatch__c> duplicates = [
            SELECT Id, Name, Status__c, Invoice__c
            FROM DMS_Dispatch__c
            WHERE Request_Key__c = :requestKey AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (!duplicates.isEmpty()) {
            if (duplicates[0].Invoice__c != invoiceId) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'This request key is already associated with a different invoice.'
                });
                return;
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'dispatch' => new Map<String, Object>{
                    'id' => duplicates[0].Id,
                    'number' => duplicates[0].Name,
                    'status' => duplicates[0].Status__c
                },
                'message' => 'This dispatch request already exists.'
            });
            return;
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Status__c, Stock_Deduction_Status__c,
                   Secondary_Order__c, Secondary_Order__r.Status,
                   Warehouse__c, Distributor__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty() || invoices[0].Status__c != 'Posted') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Dispatches can only be created for posted invoices belonging to this distributor.'
            });
            return;
        }
        DMS_Invoice__c invoice = invoices[0];
        List<Order> orders = [
            SELECT Id, OrderNumber, Status, Type, DMS_Allocation_Status__c,
                   DMS_Fulfillment_Warehouse__c
            FROM Order
            WHERE Id = :invoice.Secondary_Order__c
              AND AccountId = :distributor.Id
              AND Type = 'Secondary Order'
              AND Status = 'Activated'
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The linked approved order is no longer eligible.'
            });
            return;
        }
        if (invoice.Warehouse__c == null
            || (orders[0].DMS_Fulfillment_Warehouse__c != null
                && orders[0].DMS_Fulfillment_Warehouse__c != invoice.Warehouse__c)
            || [SELECT Id FROM Warehouse__c
                WHERE Id = :invoice.Warehouse__c
                  AND Distributor__c = :distributor.Id
                  AND Warehouse_Type__c = 'Distributor Warehouse'
                  AND Warehouse_Status__c = 'Active' LIMIT 1].isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice fulfillment warehouse is missing, inactive, or not assigned to this order.'
            });
            return;
        }
        Boolean legacyDeducted = invoice.Stock_Deduction_Status__c
            == 'Already Deducted (Legacy)';
        if (String.isBlank(invoice.Stock_Deduction_Status__c)) {
            Integer legacyTransactionCount = [
                SELECT COUNT()
                FROM Inventory_Transaction__c
                WHERE DMS_Invoice__c = :invoice.Id
                  AND Transaction_Type__c = 'Secondary Order Sale'
            ];
            if (legacyTransactionCount == 0) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The invoice stock history is incomplete; an administrator must review it before dispatch.'
                });
                return;
            }
            invoice.Stock_Deduction_Status__c = 'Already Deducted (Legacy)';
            update invoice;
            legacyDeducted = true;
        }
        if (invoice.Stock_Deduction_Status__c == 'Deducted at Dispatch') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'This invoice has already been fully dispatched.'
            });
            return;
        }
        if (!new Set<String>{
            'Pending Dispatch', 'Partially Dispatched', 'Already Deducted (Legacy)'
        }.contains(invoice.Stock_Deduction_Status__c)) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice is not eligible for dispatch.'
            });
            return;
        }

        Set<Id> orderItemIds = new Set<Id>();
        Map<Id, Decimal> quantityByOrderItem = new Map<Id, Decimal>();
        for (Object rawLine : requestedLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each dispatch line must identify an order item and positive quantity.'
                });
                return;
            }
            Map<String, Object> item = (Map<String, Object>) rawLine;
            Id orderItemId = parseId(item.get('orderItemId'));
            Decimal quantity = decimalValue(item.get('quantity'));
            if (orderItemId == null || quantity == null || quantity <= 0
                || quantity != quantity.setScale(2, RoundingMode.DOWN)
                || quantityByOrderItem.containsKey(orderItemId)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Dispatch quantities must be positive, unique per order line, and have at most two decimal places.'
                });
                return;
            }
            orderItemIds.add(orderItemId);
            quantityByOrderItem.put(orderItemId, quantity);
        }
        Map<Id, DMS_Invoice_Line__c> invoiceLineByOrderItem =
            new Map<Id, DMS_Invoice_Line__c>();
        for (DMS_Invoice_Line__c invoiceLine : [
            SELECT Id, Order_Line_Item__c, Product__c, Product__r.Name,
                   Quantity__c, Unit_of_Measure__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id AND Order_Line_Item__c IN :orderItemIds
        ]) {
            invoiceLineByOrderItem.put(invoiceLine.Order_Line_Item__c, invoiceLine);
        }
        if (invoiceLineByOrderItem.size() != orderItemIds.size()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'One or more dispatch lines do not match the invoice.'
            });
            return;
        }
        Map<Id, Decimal> alreadyDispatched = getDispatchedQuantities(
            new Set<String>{
                'Draft', 'Submitted', 'Approved', 'Dispatched',
                'Partially Delivered', 'Delivered'
            },
            new Set<Id>{invoice.Id}
        );
        for (Id orderItemId : orderItemIds) {
            DMS_Invoice_Line__c invoiceLine = invoiceLineByOrderItem.get(orderItemId);
            Decimal priorQuantity = alreadyDispatched.containsKey(orderItemId)
                ? alreadyDispatched.get(orderItemId)
                : 0;
            if (priorQuantity + quantityByOrderItem.get(orderItemId) > invoiceLine.Quantity__c) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'A requested dispatch quantity exceeds the remaining invoice quantity.'
                });
                return;
            }
        }

        DMS_Dispatch__c dispatch = new DMS_Dispatch__c(
            OwnerId = distributor.OwnerId,
            Distributor__c = distributor.Id,
            Invoice__c = invoice.Id,
            Order__c = orders[0].Id,
            Warehouse__c = invoice.Warehouse__c,
            Approver__c = null,
            Dispatch_Date__c = Date.today(),
            Expected_Delivery_Date__c = parseDate(payload.get('expectedDeliveryDate')),
            Transporter_Name__c = stringValue(payload.get('transporterName')),
            Vehicle_Number__c = stringValue(payload.get('vehicleNumber')),
            Tracking_Number__c = stringValue(payload.get('trackingNumber')),
            Notes__c = stringValue(payload.get('notes')),
            Status__c = 'Draft',
            Delivery_Status__c = 'Pending',
            Request_Key__c = requestKey
        );
        insert dispatch;
        List<DMS_Dispatch_Line__c> dispatchLines = new List<DMS_Dispatch_Line__c>();
        for (Id orderItemId : orderItemIds) {
            DMS_Invoice_Line__c invoiceLine = invoiceLineByOrderItem.get(orderItemId);
            dispatchLines.add(new DMS_Dispatch_Line__c(
                Dispatch__c = dispatch.Id,
                Order_Line_Item__c = orderItemId,
                Product__c = invoiceLine.Product__c,
                Product_Name_Snapshot__c = invoiceLine.Product__r.Name,
                Quantity__c = quantityByOrderItem.get(orderItemId),
                Quantity_Delivered__c = 0,
                Quantity_Short__c = 0,
                Quantity_Damaged__c = 0,
                Unit_of_Measure__c = invoiceLine.Unit_of_Measure__c
            ));
        }
        insert dispatchLines;
        writeResponse(response, 201, new Map<String, Object>{
            'success' => true,
            'dispatch' => new Map<String, Object>{
                'id' => dispatch.Id,
                'number' => dispatch.Name,
                'status' => dispatch.Status__c,
                'legacyStockAlreadyDeducted' => legacyDeducted
            },
            'message' => 'Dispatch draft created. Confirm the physical dispatch when the goods leave the warehouse.'
        });
    }

    private static void submitDispatch(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id dispatchId = parseId(payload.get('dispatchId'));
        if (dispatchId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid dispatchId is required.'
            });
            return;
        }
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Status__c, Approver__c, Order__r.Type
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (dispatches.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Dispatch not found.'
            });
            return;
        }
        if (dispatches[0].Order__r == null
            || dispatches[0].Order__r.Type != 'Secondary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary dispatches are managed by the company in Salesforce and are read-only in the distributor portal.'
            });
            return;
        }
        writeResponse(response, 409, new Map<String, Object>{
            'success' => false,
            'message' => 'Secondary dispatches do not require approval. Confirm the physical dispatch directly.'
        });
    }

    private static void confirmDispatch(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id dispatchId = parseId(payload.get('dispatchId'));
        if (dispatchId == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid dispatchId is required.'
            });
            return;
        }
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Name, Invoice__c, Invoice__r.Stock_Deduction_Status__c,
                   Order__c, Warehouse__c, Status__c, Distributor__c,
                   Invoice__r.Status__c, Order__r.Status, Order__r.Type,
                   Order__r.DMS_Allocation_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (dispatches.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Dispatch not found.'
            });
            return;
        }
        DMS_Dispatch__c dispatch = dispatches[0];
        if (dispatch.Order__r == null || dispatch.Order__r.Type != 'Secondary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary dispatches are managed by the company in Salesforce and are read-only in the distributor portal.'
            });
            return;
        }
        if (dispatch.Status__c == 'Dispatched'
            || dispatch.Status__c == 'Partially Delivered'
            || dispatch.Status__c == 'Delivered') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'message' => 'Dispatch has already been confirmed.',
                'status' => dispatch.Status__c
            });
            return;
        }
        if (dispatch.Status__c != 'Draft' && dispatch.Status__c != 'Submitted'
            && dispatch.Status__c != 'Approved') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'This dispatch cannot be confirmed in its current status.'
            });
            return;
        }
        if (dispatch.Invoice__r == null || dispatch.Invoice__r.Status__c != 'Posted'
            || dispatch.Order__r == null || dispatch.Order__r.Status != 'Activated'
            || (dispatch.Order__r.Type != 'Primary Order'
                && dispatch.Order__r.Type != 'Secondary Order')) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The invoice or approved order is no longer eligible for dispatch.'
            });
            return;
        }

        List<DMS_Invoice__c> invoiceRows = [
            SELECT Id, Name, Stock_Deduction_Status__c, Warehouse__c
            FROM DMS_Invoice__c
            WHERE Id = :dispatch.Invoice__c AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (invoiceRows.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The linked invoice is unavailable.'
            });
            return;
        }
        List<Order> orderRows = [
            SELECT Id, OrderNumber, Status, DMS_Allocation_Status__c
            FROM Order
            WHERE Id = :dispatch.Order__c AND AccountId = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (orderRows.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The linked order is unavailable.'
            });
            return;
        }
        if ([SELECT Id FROM Warehouse__c
             WHERE Id = :dispatch.Warehouse__c
               AND Distributor__c = :distributor.Id
               AND Warehouse_Type__c = 'Distributor Warehouse'
               AND Warehouse_Status__c = 'Active' LIMIT 1].isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The fulfillment warehouse is inactive or unavailable.'
            });
            return;
        }

        List<DMS_Dispatch_Line__c> lines = [
            SELECT Id, Order_Line_Item__c, Product__c, Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
            FOR UPDATE
        ];
        if (lines.isEmpty()) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The dispatch has no lines.'
            });
            return;
        }
        Integer priorDispatchTransactions = [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Dispatch__c = :dispatch.Id
              AND Transaction_Type__c = 'Secondary Order Sale'
        ];
        if (priorDispatchTransactions > 0) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Inventory transactions already exist for this dispatch; contact your administrator.'
            });
            return;
        }
        Boolean legacyDeducted = invoiceRows[0].Stock_Deduction_Status__c
            == 'Already Deducted (Legacy)';
        if (!legacyDeducted) {
            String stockStatus = invoiceRows[0].Stock_Deduction_Status__c;
            if (stockStatus != 'Pending Dispatch' && stockStatus != 'Partially Dispatched') {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The invoice stock status does not permit another dispatch.'
                });
                return;
            }
            String stockError = applyDispatchStock(
                dispatch,
                orderRows[0],
                lines,
                distributor.Id
            );
            if (stockError != null) {
                writeResponse(response, 409, new Map<String, Object>{
                    'success' => false,
                    'message' => stockError
                });
                return;
            }
        }

        dispatch.Status__c = 'Dispatched';
        dispatch.Delivery_Status__c = 'In Transit';
        dispatch.Actual_Dispatch_Date__c = System.now();
        update dispatch;
        if (!legacyDeducted) {
            Map<Id, Decimal> dispatchedAfter = getDispatchedQuantities(
                new Set<String>{
                    'Dispatched', 'Partially Delivered', 'Delivered'
                },
                new Set<Id>{dispatch.Invoice__c}
            );
            Boolean orderComplete = true;
            for (AggregateResult result : [
                SELECT Order_Line_Item__c lineId, SUM(Quantity__c) totalQuantity
                FROM DMS_Invoice_Line__c
                WHERE Invoice__c = :dispatch.Invoice__c
                GROUP BY Order_Line_Item__c
            ]) {
                Id orderItemId = (Id) result.get('lineId');
                Decimal invoicedQuantity = (Decimal) result.get('totalQuantity');
                if ((dispatchedAfter.containsKey(orderItemId)
                        ? dispatchedAfter.get(orderItemId)
                        : 0) < invoicedQuantity) {
                    orderComplete = false;
                }
            }
            invoiceRows[0].Stock_Deduction_Status__c = orderComplete
                ? 'Deducted at Dispatch'
                : 'Partially Dispatched';
            update invoiceRows[0];
        }
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'message' => legacyDeducted
                ? 'Dispatch confirmed. Stock was already deducted by the legacy invoice workflow and was not deducted again.'
                : 'Dispatch confirmed and inventory deducted once.',
            'dispatchId' => dispatch.Id,
            'status' => dispatch.Status__c,
            'legacyStockAlreadyDeducted' => legacyDeducted
        });
    }

    private static String applyDispatchStock(
        DMS_Dispatch__c dispatch,
        Order salesOrder,
        List<DMS_Dispatch_Line__c> dispatchLines,
        Id distributorId
    ) {
        Set<Id> orderItemIds = new Set<Id>();
        for (DMS_Dispatch_Line__c line : dispatchLines) orderItemIds.add(line.Order_Line_Item__c);
        Map<Id, OrderItem> orderItemById = new Map<Id, OrderItem>([
            SELECT Id, Product2Id, Quantity, Unit_Conversion_Factor__c
            FROM OrderItem
            WHERE Id IN :orderItemIds AND OrderId = :salesOrder.Id
        ]);
        if (orderItemById.size() != orderItemIds.size()) {
            return 'A dispatch line no longer matches the approved order.';
        }

        Map<Id, Decimal> dispatchedNowByProduct = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c line : dispatchLines) {
            OrderItem orderItem = orderItemById.get(line.Order_Line_Item__c);
            Decimal factor = orderItem.Unit_Conversion_Factor__c == null
                ? 1
                : orderItem.Unit_Conversion_Factor__c;
            if (line.Quantity__c == null || line.Quantity__c <= 0
                || factor <= 0 || line.Quantity__c > orderItem.Quantity) {
                return 'A dispatch line contains an invalid quantity or unit conversion.';
            }
            dispatchedNowByProduct.put(
                orderItem.Product2Id,
                (dispatchedNowByProduct.containsKey(orderItem.Product2Id)
                    ? dispatchedNowByProduct.get(orderItem.Product2Id)
                    : 0) + line.Quantity__c * factor
            );
        }

        String reservationPattern = 'DMS-RES-' + String.valueOf(salesOrder.Id) + '-%';
        Set<String> reservationTypes = new Set<String>{'Stock Reservation', 'Stock Release'};
        Map<String, Decimal> activeByReferenceInventory = new Map<String, Decimal>();
        Map<String, Id> inventoryByReferenceInventory = new Map<String, Id>();
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
            Decimal current = activeByReferenceInventory.containsKey(key)
                ? activeByReferenceInventory.get(key)
                : 0;
            activeByReferenceInventory.put(
                key,
                current + (reservationRecord.Transaction_Type__c == 'Stock Reservation'
                    ? reservationRecord.Quantity__c
                    : -reservationRecord.Quantity__c)
            );
            inventoryByReferenceInventory.put(key, reservationRecord.Inventory__c);
            productByInventory.put(
                reservationRecord.Inventory__c,
                reservationRecord.Inventory__r.Product__c
            );
            warehouseByInventory.put(
                reservationRecord.Inventory__c,
                reservationRecord.Inventory__r.Warehouse__c
            );
        }

        Boolean hasActiveReservation = false;
        Map<Id, Decimal> activeByProduct = new Map<Id, Decimal>();
        for (String key : activeByReferenceInventory.keySet()) {
            Decimal quantity = activeByReferenceInventory.get(key);
            if (quantity < 0) {
                return 'The order reservation ledger is inconsistent. Contact your administrator.';
            }
            if (quantity == 0) continue;
            Id inventoryId = inventoryByReferenceInventory.get(key);
            if (warehouseByInventory.get(inventoryId) != dispatch.Warehouse__c) {
                return 'The active order reservation belongs to a different warehouse.';
            }
            hasActiveReservation = true;
            Id productId = productByInventory.get(inventoryId);
            activeByProduct.put(
                productId,
                (activeByProduct.containsKey(productId) ? activeByProduct.get(productId) : 0)
                    + quantity
            );
        }
        if (salesOrder.DMS_Allocation_Status__c == 'Reserved' && !hasActiveReservation) {
            return 'The order is marked Reserved, but no active reservation was found.';
        }
        if (hasActiveReservation) {
            for (Id productId : dispatchedNowByProduct.keySet()) {
                if (!activeByProduct.containsKey(productId)
                    || activeByProduct.get(productId) < dispatchedNowByProduct.get(productId)) {
                    return 'The active reservation does not cover the requested dispatch quantities.';
                }
            }
        }

        List<Inventory__c> inventoryRecords = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :dispatch.Warehouse__c
              AND Product__c IN :dispatchedNowByProduct.keySet()
            FOR UPDATE
        ];
        Map<Id, Inventory__c> inventoryByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c inventory : inventoryRecords) {
            if (inventoryByProduct.containsKey(inventory.Product__c)) {
                return 'Duplicate inventory balances exist for a product and warehouse.';
            }
            inventoryByProduct.put(inventory.Product__c, inventory);
        }
        for (Id productId : dispatchedNowByProduct.keySet()) {
            Inventory__c inventory = inventoryByProduct.get(productId);
            if (inventory == null) return 'No inventory balance exists for a dispatch product.';
            Decimal quantity = dispatchedNowByProduct.get(productId);
            Decimal balance = hasActiveReservation
                ? (inventory.Reserved_Quantity__c == null ? 0 : inventory.Reserved_Quantity__c)
                : (inventory.Available_Quantity__c == null ? 0 : inventory.Available_Quantity__c);
            if (balance < quantity) {
                return hasActiveReservation
                    ? 'Reserved inventory is insufficient to confirm this dispatch.'
                    : 'Available inventory is insufficient to confirm this dispatch.';
            }
        }

        List<Inventory_Transaction__c> transactions = new List<Inventory_Transaction__c>();
        for (Id productId : dispatchedNowByProduct.keySet()) {
            Decimal baseQuantity = dispatchedNowByProduct.get(productId);
            Inventory__c inventory = inventoryByProduct.get(productId);
            if (hasActiveReservation) inventory.Reserved_Quantity__c -= baseQuantity;
            else inventory.Available_Quantity__c -= baseQuantity;
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = inventory.Id,
                Transaction_Type__c = 'Secondary Order Sale',
                Quantity__c = baseQuantity,
                Transaction_Date__c = System.now(),
                Reference_Number__c = dispatch.Name,
                Transaction_Description__c = 'Physical stock deducted when dispatch was confirmed',
                DMS_Invoice__c = dispatch.Invoice__c,
                DMS_Dispatch__c = dispatch.Id
            ));
        }
        if (hasActiveReservation) {
            Map<Id, Decimal> quantityToReleaseByProduct =
                new Map<Id, Decimal>(dispatchedNowByProduct);
            for (String key : activeByReferenceInventory.keySet()) {
                Decimal activeQuantity = activeByReferenceInventory.get(key);
                if (activeQuantity <= 0) continue;
                Id inventoryId = inventoryByReferenceInventory.get(key);
                Id productId = productByInventory.get(inventoryId);
                Decimal remainingToRelease = quantityToReleaseByProduct.containsKey(productId)
                    ? quantityToReleaseByProduct.get(productId)
                    : 0;
                if (remainingToRelease <= 0) continue;
                Decimal releaseQuantity = Math.min(activeQuantity, remainingToRelease);
                transactions.add(new Inventory_Transaction__c(
                    Inventory__c = inventoryId,
                    Transaction_Type__c = 'Stock Release',
                    Quantity__c = releaseQuantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = key.substring(0, key.lastIndexOf(':')),
                    Transaction_Description__c = 'Order reservation consumed by dispatch ' + dispatch.Name,
                    DMS_Invoice__c = dispatch.Invoice__c,
                    DMS_Dispatch__c = dispatch.Id
                ));
                quantityToReleaseByProduct.put(productId, remainingToRelease - releaseQuantity);
            }
            for (Id productId : quantityToReleaseByProduct.keySet()) {
                if (quantityToReleaseByProduct.get(productId) > 0) {
                    return 'The reservation ledger could not cover the dispatch quantities.';
                }
            }
        }
        update inventoryRecords;
        insert transactions;
        return null;
    }

    private static void recordDelivery(
        Account distributor,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id dispatchId = parseId(payload.get('dispatchId'));
        List<Object> deliveredLines = payload.get('lines') instanceof List<Object>
            ? (List<Object>) payload.get('lines')
            : new List<Object>();
        if (dispatchId == null || deliveredLines.isEmpty()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A dispatched record and delivery quantities are required.'
            });
            return;
        }
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Status__c, Delivery_Status__c, Order__r.Type
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (dispatches.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'Dispatch not found.'
            });
            return;
        }
        DMS_Dispatch__c dispatch = dispatches[0];
        if (dispatch.Order__r == null || dispatch.Order__r.Type != 'Secondary Order') {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'Primary dispatches are managed by the company in Salesforce and are read-only in the distributor portal.'
            });
            return;
        }
        if (dispatch.Status__c != 'Dispatched'
            && dispatch.Status__c != 'Partially Delivered') {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Delivery can only be recorded for a physically dispatched shipment.'
            });
            return;
        }
        Map<Id, Map<String, Object>> inputByLineId =
            new Map<Id, Map<String, Object>>();
        for (Object rawLine : deliveredLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each delivery line must identify its dispatch line.'
                });
                return;
            }
            Map<String, Object> input = (Map<String, Object>) rawLine;
            Id lineId = parseId(input.get('dispatchLineId'));
            if (lineId == null || inputByLineId.containsKey(lineId)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Each dispatch line can be reported only once per delivery confirmation.'
                });
                return;
            }
            inputByLineId.put(lineId, input);
        }
        List<DMS_Dispatch_Line__c> lines = [
            SELECT Id, Quantity__c, Quantity_Delivered__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
            FOR UPDATE
        ];
        if (lines.isEmpty() || lines.size() != inputByLineId.size()) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Provide delivery quantities for every dispatch line.'
            });
            return;
        }
        Boolean allDelivered = true;
        for (DMS_Dispatch_Line__c line : lines) {
            Map<String, Object> input = inputByLineId.get(line.Id);
            if (input == null) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'A dispatch line is missing from the delivery confirmation.'
                });
                return;
            }
            Decimal delivered = decimalValue(input.get('deliveredQuantity'));
            Decimal damaged = decimalValue(input.get('damagedQuantity'));
            if (delivered == null || damaged == null || delivered < 0 || damaged < 0
                || damaged > delivered || delivered > line.Quantity__c
                || delivered < (line.Quantity_Delivered__c == null
                    ? 0
                    : line.Quantity_Delivered__c)) {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'Delivered and damaged quantities must be valid and cannot exceed the dispatched quantity.'
                });
                return;
            }
            line.Quantity_Delivered__c = delivered;
            line.Quantity_Damaged__c = damaged;
            line.Quantity_Short__c = line.Quantity__c - delivered;
            if (delivered < line.Quantity__c) allDelivered = false;
        }
        String recipientName = stringValue(payload.get('recipientName'));
        if (String.isBlank(recipientName)) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Recipient name is required to record delivery.'
            });
            return;
        }
        update lines;
        dispatch.Recipient_Name__c = recipientName;
        dispatch.Delivery_Remarks__c = stringValue(payload.get('remarks'));
        dispatch.Actual_Delivery_Date__c = System.now();
        dispatch.Delivery_Status__c = allDelivered ? 'Delivered' : 'Partially Delivered';
        dispatch.Status__c = allDelivered ? 'Delivered' : 'Partially Delivered';
        update dispatch;
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'status' => dispatch.Status__c,
            'deliveryStatus' => dispatch.Delivery_Status__c,
            'message' => allDelivered
                ? 'Delivery confirmation recorded.'
                : 'Partial delivery and outstanding quantities recorded.'
        });
    }

    private static Map<Id, Decimal> getDispatchedQuantities(
        Set<String> statuses,
        Set<Id> invoiceIds
    ) {
        Map<Id, Decimal> quantities = new Map<Id, Decimal>();
        if (invoiceIds.isEmpty()) return quantities;
        for (AggregateResult result : [
            SELECT Order_Line_Item__c orderItemId, SUM(Quantity__c) totalQuantity
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__r.Invoice__c IN :invoiceIds
              AND Dispatch__r.Status__c IN :statuses
            GROUP BY Order_Line_Item__c
        ]) {
            Id orderItemId = (Id) result.get('orderItemId');
            quantities.put(orderItemId, (Decimal) result.get('totalQuantity'));
        }
        return quantities;
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

    private static Map<String, Object> dispatchSummary(
        DMS_Dispatch__c dispatch,
        String approvalStatus
    ) {
        String status = dispatch.Status__c;
        if (status == 'Draft' && approvalStatus == 'Pending') status = 'Submitted';
        if (status == 'Draft' && approvalStatus == 'Approved') status = 'Approved';
        if (status == 'Draft' && approvalStatus == 'Rejected') status = 'Rejected';
        return new Map<String, Object>{
            'id' => dispatch.Id,
            'number' => dispatch.Name,
            'invoiceId' => dispatch.Invoice__c,
            'invoiceNumber' => dispatch.Invoice__r == null ? null : dispatch.Invoice__r.Name,
            'orderId' => dispatch.Order__c,
            'orderNumber' => dispatch.Order__r == null ? null : dispatch.Order__r.OrderNumber,
            'orderType' => dispatch.Order__r == null ? null : dispatch.Order__r.Type,
            'warehouseName' => dispatch.Warehouse__r == null ? null : dispatch.Warehouse__r.Name,
            'status' => status,
            'deliveryStatus' => dispatch.Delivery_Status__c,
            'dispatchDate' => dispatch.Dispatch_Date__c,
            'expectedDeliveryDate' => dispatch.Expected_Delivery_Date__c,
            'actualDispatchDate' => dispatch.Actual_Dispatch_Date__c,
            'actualDeliveryDate' => dispatch.Actual_Delivery_Date__c,
            'transporterName' => dispatch.Transporter_Name__c,
            'vehicleNumber' => dispatch.Vehicle_Number__c,
            'trackingNumber' => dispatch.Tracking_Number__c,
            'recipientName' => dispatch.Recipient_Name__c,
            'deliveryRemarks' => dispatch.Delivery_Remarks__c
        };
    }

    private static String getDispatchLineType(Decimal paidQuantity, Decimal freeQuantity) {
        Boolean hasPaid = paidQuantity != null && paidQuantity > 0;
        Boolean hasFree = freeQuantity != null && freeQuantity > 0;
        if (hasPaid && hasFree) return 'Paid + Free';
        if (hasFree) return 'Free';
        if (hasPaid) return 'Paid';
        return 'Not recorded';
    }

    private static Integer countDispatches(
        List<DMS_Dispatch__c> dispatches,
        Map<Id, String> approvals,
        String requestedStatus
    ) {
        Integer count = 0;
        for (DMS_Dispatch__c dispatch : dispatches) {
            String status = dispatch.Status__c;
            if (status == 'Draft' && approvals.get(dispatch.Id) == 'Pending') {
                status = 'Submitted';
            }
            if (status == requestedStatus) count++;
        }
        return count;
    }

    private static Integer countDeliveryExceptions(List<DMS_Dispatch__c> dispatches) {
        Integer count = 0;
        for (DMS_Dispatch__c dispatch : dispatches) {
            if (dispatch.Delivery_Status__c == 'Partially Delivered'
                || dispatch.Delivery_Status__c == 'Failed'
                || dispatch.Delivery_Status__c == 'Rescheduled'
                || dispatch.Delivery_Status__c == 'Returned to Sender') count++;
        }
        return count;
    }

    private static List<String> submitForApproval(
        Id recordId,
        Id submitterId,
        String comments
    ) {
        List<String> messages = new List<String>();
        Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
        request.setObjectId(recordId);
        request.setSubmitterId(String.valueOf(submitterId));
        request.setComments(comments);
        Approval.ProcessResult result = Approval.process(request);
        if (result.isSuccess()) return messages;
        if (result.getErrors().isEmpty()) {
            messages.add('No matching active Salesforce approval process is configured.');
            return messages;
        }
        for (Database.Error error : result.getErrors()) messages.add(error.getMessage());
        return messages;
    }

    private static Id getDistributorOwnerManagerId(Account distributor) {
        if (distributor == null || distributor.OwnerId == null
            || !String.valueOf(distributor.OwnerId).startsWith('005')) return null;
        List<User> owners = [
            SELECT ManagerId
            FROM User
            WHERE Id = :distributor.OwnerId AND IsActive = true
            LIMIT 1
        ];
        if (owners.isEmpty() || owners[0].ManagerId == null) return null;
        List<User> managers = [
            SELECT Id
            FROM User
            WHERE Id = :owners[0].ManagerId AND IsActive = true
            LIMIT 1
        ];
        return managers.isEmpty() ? null : managers[0].Id;
    }

    private static Id getActiveOrderApproverId(Id approverId) {
        if (approverId == null || !String.valueOf(approverId).startsWith('005')) return null;
        List<User> approvers = [
            SELECT Id
            FROM User
            WHERE Id = :approverId AND IsActive = true
            LIMIT 1
        ];
        return approvers.isEmpty() ? null : approvers[0].Id;
    }

    private static Account findDistributor(String token) {
        if (String.isBlank(token) || token.length() != 64
            || !Pattern.matches('^[a-fA-F0-9]{64}$', token)) return null;
        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
        Datetime currentTime = System.now();
        List<Account> distributors = [
            SELECT Id, Name, OwnerId
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
        for (String key : RestContext.request.headers.keySet()) {
            if (key.equalsIgnoreCase('X-DMS-Session')) {
                String token = RestContext.request.headers.get(key);
                return String.isBlank(token) ? null : token.trim();
            }
        }
        return null;
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

    private static Date parseDate(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) return null;
        try {
            return Date.valueOf(String.valueOf(value));
        } catch (Exception error) {
            return null;
        }
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> body
    ) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}
