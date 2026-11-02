@RestResource(urlMapping='/dms/company/v1/primary/*')
global without sharing class DMSCompanyPrimaryWorkflowResource {
    private static final String COMPANY_PERMISSION = 'DMS_Company_Inventory_Access';
    private static final String COMPANY_WAREHOUSE = 'Company Warehouse';
    private static final Set<String> ACTIVE_DISPATCH_STATUSES = new Set<String>{
        'Draft', 'Submitted', 'Approved', 'Dispatched', 'Partially Delivered', 'Delivered'
    };

    @HttpGet
    global static void getCompanyInventory() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        if (!isCompanyOperator()) {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'You are not authorized to access company inventory.'
            });
            return;
        }

        try {
            List<Map<String, Object>> stock = new List<Map<String, Object>>();
            for (Inventory__c balance : [
                SELECT Id, Product__c, Product__r.Name, Product__r.ProductCode,
                       Warehouse__c, Warehouse__r.Name, Warehouse__r.Warehouse_Code__c,
                       Available_Quantity__c, Reserved_Quantity__c,
                       Minimum_Stock_Level__c, Stock_Status__c
                FROM Inventory__c
                WHERE Warehouse__r.Warehouse_Type__c = :COMPANY_WAREHOUSE
                  AND Warehouse__r.Distributor__c = null
                ORDER BY Warehouse__r.Name, Product__r.Name
                LIMIT 2000
            ]) {
                stock.add(new Map<String, Object>{
                    'inventoryId' => balance.Id,
                    'productId' => balance.Product__c,
                    'productName' => balance.Product__r == null ? null : balance.Product__r.Name,
                    'productCode' => balance.Product__r == null ? null : balance.Product__r.ProductCode,
                    'warehouseId' => balance.Warehouse__c,
                    'warehouseName' => balance.Warehouse__r == null ? null : balance.Warehouse__r.Name,
                    'warehouseCode' => balance.Warehouse__r == null
                        ? null
                        : balance.Warehouse__r.Warehouse_Code__c,
                    'availableQuantity' => balance.Available_Quantity__c == null
                        ? 0
                        : balance.Available_Quantity__c,
                    'reservedQuantity' => balance.Reserved_Quantity__c == null
                        ? 0
                        : balance.Reserved_Quantity__c,
                    'minimumStockLevel' => balance.Minimum_Stock_Level__c,
                    'stockStatus' => balance.Stock_Status__c
                });
            }
            List<Map<String, Object>> warehouses = new List<Map<String, Object>>();
            for (Warehouse__c warehouse : [
                SELECT Id, Name, Warehouse_Code__c, Warehouse_Address__c,
                       City__c, State__c, PIN_Code__c
                FROM Warehouse__c
                WHERE Warehouse_Type__c = :COMPANY_WAREHOUSE
                  AND Distributor__c = null
                  AND Warehouse_Status__c = 'Active'
                ORDER BY Name
                LIMIT 500
            ]) {
                warehouses.add(new Map<String, Object>{
                    'id' => warehouse.Id,
                    'name' => warehouse.Name,
                    'code' => warehouse.Warehouse_Code__c,
                    'address' => warehouse.Warehouse_Address__c,
                    'city' => warehouse.City__c,
                    'state' => warehouse.State__c,
                    'postalCode' => warehouse.PIN_Code__c
                });
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'inventory' => stock,
                'warehouses' => warehouses
            });
        } catch (Exception error) {
            logFailure('Company inventory query failed', error);
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'Company inventory could not be loaded.'
            });
        }
    }

    @HttpPost
    global static void postCompanyAction() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        if (!isCompanyOperator()) {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'You are not authorized to perform company primary operations.'
            });
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
        } catch (Exception error) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid JSON request body is required.'
            });
            return;
        }
        if (payload == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid JSON request body is required.'
            });
            return;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            String action = stringValue(payload.get('action'));
            Map<String, Object> result;
            if (action == 'createInvoice') {
                result = createPrimaryInvoice(payload);
            } else if (action == 'postInvoice') {
                result = postPrimaryInvoice(payload);
            } else if (action == 'createDispatch') {
                result = createPrimaryDispatch(payload);
            } else if (action == 'submitDispatch') {
                result = submitPrimaryDispatch(payload);
            } else if (action == 'confirmDispatch') {
                result = confirmPrimaryDispatch(payload);
            } else if (action == 'updateDelivery') {
                result = updatePrimaryDelivery(payload);
            } else {
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The requested company operation is not supported.'
                });
                return;
            }
            result.put('success', true);
            writeResponse(response, 200, result);
        } catch (WorkflowRequestException error) {
            Database.rollback(savepoint);
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (WorkflowConflictException error) {
            Database.rollback(savepoint);
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (Exception error) {
            Database.rollback(savepoint);
            logFailure('Company primary workflow failed', error);
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The company primary operation could not be completed.'
            });
        }
    }

    private static Map<String, Object> createPrimaryInvoice(Map<String, Object> payload) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id orderId = parseId(payload.get('orderId'), Order.SObjectType);
        Id warehouseId = parseId(payload.get('warehouseId'), Warehouse__c.SObjectType);
        if (String.isBlank(requestKey) || requestKey.length() > 80
            || orderId == null || warehouseId == null) {
            throw new WorkflowRequestException(
                'A request key, approved Primary Order, and Company Warehouse are required.'
            );
        }

        List<DMS_Invoice__c> retries = [
            SELECT Id, Name, Status__c, Secondary_Order__c, Warehouse__c
            FROM DMS_Invoice__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];
        if (!retries.isEmpty()) {
            DMS_Invoice__c existing = retries[0];
            if (existing.Secondary_Order__c != orderId || existing.Warehouse__c != warehouseId) {
                throw new WorkflowConflictException(
                    'This invoice request key is already associated with different details.'
                );
            }
            return invoiceResponse(existing, true);
        }

        Warehouse__c warehouse = requireCompanyWarehouse(warehouseId);
        List<Order> orders = [
            SELECT Id, OrderNumber, AccountId, Account.Name, Type, Status
            FROM Order
            WHERE Id = :orderId AND Type = 'Primary Order' AND Status = 'Activated'
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty() || !hasApprovedProcess(orders[0].Id)) {
            throw new WorkflowConflictException(
                'Only an approved, activated Primary Order can be invoiced.'
            );
        }
        Order salesOrder = orders[0];
        if (![SELECT Id FROM DMS_Invoice__c
              WHERE Secondary_Order__c = :salesOrder.Id
                AND Status__c != 'Cancelled'
              LIMIT 1].isEmpty()) {
            throw new WorkflowConflictException(
                'This Primary Order already has an invoice.'
            );
        }

        List<OrderItem> items = [
            SELECT Id, Product2Id, Product2.Name, Product2.IsActive,
                   Product2.DMS_Tax_Rate__c, Quantity, UnitPrice, ListPrice,
                   DMS_List_Price__c, Unit_of_Measure__c, DMS_Tax_Rate__c,
                   DMS_Tax_Amount__c
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ];
        if (items.isEmpty()) {
            throw new WorkflowConflictException('The Primary Order has no invoiceable lines.');
        }

        Decimal subtotal = 0;
        Decimal discount = 0;
        Decimal taxable = 0;
        Decimal tax = 0;
        List<DMS_Invoice_Line__c> invoiceLines = new List<DMS_Invoice_Line__c>();
        for (OrderItem item : items) {
            Decimal listPrice = item.DMS_List_Price__c == null
                ? item.ListPrice
                : item.DMS_List_Price__c;
            Decimal rate = item.DMS_Tax_Rate__c == null
                ? (item.Product2.DMS_Tax_Rate__c == null ? 0 : item.Product2.DMS_Tax_Rate__c)
                : item.DMS_Tax_Rate__c;
            if (item.Product2Id == null || !item.Product2.IsActive
                || item.Quantity == null || item.Quantity <= 0
                || item.UnitPrice == null || item.UnitPrice < 0
                || listPrice == null || listPrice < item.UnitPrice
                || rate < 0 || rate > 100) {
                throw new WorkflowConflictException(
                    'The Primary Order contains an invalid product, quantity, price, or tax configuration.'
                );
            }
            Decimal gross = (listPrice * item.Quantity).setScale(2);
            Decimal lineDiscount = ((listPrice - item.UnitPrice) * item.Quantity).setScale(2);
            Decimal lineTaxable = (item.UnitPrice * item.Quantity).setScale(2);
            Decimal lineTax = item.DMS_Tax_Amount__c == null
                ? (lineTaxable * rate / 100).setScale(2)
                : item.DMS_Tax_Amount__c.setScale(2);
            if (lineTax < 0) {
                throw new WorkflowConflictException('The Primary Order contains a negative tax amount.');
            }
            subtotal += gross;
            discount += lineDiscount;
            taxable += lineTaxable;
            tax += lineTax;
            invoiceLines.add(new DMS_Invoice_Line__c(
                Order_Line_Item__c = item.Id,
                Product__c = item.Product2Id,
                Quantity__c = item.Quantity,
                Unit_Price__c = item.UnitPrice,
                Gross_Amount__c = gross,
                Discount_Amount__c = lineDiscount,
                Taxable_Amount__c = lineTaxable,
                Tax_Rate__c = rate,
                Tax_Amount__c = lineTax,
                Line_Total__c = lineTaxable + lineTax,
                Unit_of_Measure__c = item.Unit_of_Measure__c
            ));
        }

        DMS_Invoice__c invoice = new DMS_Invoice__c(
            Invoice_Date__c = Date.today(),
            Distributor__c = salesOrder.AccountId,
            Retailer__c = salesOrder.AccountId,
            Secondary_Order__c = salesOrder.Id,
            Warehouse__c = warehouse.Id,
            Status__c = 'Draft',
            Subtotal__c = subtotal.setScale(2),
            Total_Discount__c = discount.setScale(2),
            Taxable_Amount__c = taxable.setScale(2),
            Tax_Amount__c = tax.setScale(2),
            Invoice_Total__c = (taxable + tax).setScale(2),
            Credited_Amount__c = 0,
            Amount_Paid__c = 0,
            Balance_Due__c = (taxable + tax).setScale(2),
            Stock_Deduction_Status__c = 'Pending Dispatch',
            Request_Key__c = requestKey
        );
        insert invoice;
        for (DMS_Invoice_Line__c invoiceLine : invoiceLines) {
            invoiceLine.Invoice__c = invoice.Id;
        }
        insert invoiceLines;
        return invoiceResponse(invoice, false);
    }

    private static Map<String, Object> postPrimaryInvoice(Map<String, Object> payload) {
        Id invoiceId = parseId(payload.get('invoiceId'), DMS_Invoice__c.SObjectType);
        if (invoiceId == null) {
            throw new WorkflowRequestException('A valid Primary Invoice ID is required.');
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Status__c, Secondary_Order__c, Distributor__c,
                   Warehouse__c,
                   Retailer__c, Stock_Deduction_Status__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty()) throw new WorkflowConflictException('Primary Invoice not found.');
        DMS_Invoice__c invoice = invoices[0];
        requireCompanyWarehouse(invoice.Warehouse__c);
        List<Order> orders = [
            SELECT Id, AccountId, Type, Status
            FROM Order
            WHERE Id = :invoice.Secondary_Order__c
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty() || orders[0].Type != 'Primary Order'
            || orders[0].Status != 'Activated'
            || orders[0].AccountId != invoice.Distributor__c
            || invoice.Retailer__c != invoice.Distributor__c
            || !hasApprovedProcess(orders[0].Id)) {
            throw new WorkflowConflictException(
                'The invoice is not linked to an approved Primary Order and its distributor.'
            );
        }
        if (invoice.Status__c == 'Posted') {
            return new Map<String, Object>{
                'invoiceId' => invoice.Id,
                'invoiceNumber' => invoice.Name,
                'status' => invoice.Status__c,
                'alreadyProcessed' => true,
                'message' => 'Primary Invoice was already posted; inventory was not changed.'
            };
        }
        if (invoice.Status__c != 'Draft' || [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoice.Id LIMIT 1
        ].isEmpty()) {
            throw new WorkflowConflictException('Only a nonempty Draft Primary Invoice can be posted.');
        }
        invoice.Status__c = 'Posted';
        invoice.Posted_Date__c = System.now();
        invoice.Stock_Deduction_Status__c = 'Pending Dispatch';
        update invoice;
        return new Map<String, Object>{
            'invoiceId' => invoice.Id,
            'invoiceNumber' => invoice.Name,
            'status' => invoice.Status__c,
            'message' => 'Primary Invoice posted. Company stock is unchanged until dispatch confirmation.'
        };
    }

    private static Map<String, Object> createPrimaryDispatch(Map<String, Object> payload) {
        String requestKey = stringValue(payload.get('requestKey'));
        Id invoiceId = parseId(payload.get('invoiceId'), DMS_Invoice__c.SObjectType);
        if (String.isBlank(requestKey) || requestKey.length() > 80 || invoiceId == null) {
            throw new WorkflowRequestException('A request key and Primary Invoice are required.');
        }
        List<DMS_Dispatch__c> retries = [
            SELECT Id, Name, Invoice__c, Status__c
            FROM DMS_Dispatch__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];
        if (!retries.isEmpty()) {
            if (retries[0].Invoice__c != invoiceId) {
                throw new WorkflowConflictException(
                    'This dispatch request key is already associated with a different invoice.'
                );
            }
            validateRetryLines(retries[0].Id, payload.get('lines'));
            return new Map<String, Object>{
                'dispatchId' => retries[0].Id,
                'dispatchNumber' => retries[0].Name,
                'status' => retries[0].Status__c,
                'alreadyProcessed' => true
            };
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Status__c, Distributor__c, Secondary_Order__c,
                   Warehouse__c, Warehouse__r.Warehouse_Type__c,
                   Warehouse__r.Distributor__c, Warehouse__r.Warehouse_Status__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty() || invoices[0].Status__c != 'Posted'
            || invoices[0].Retailer__c != invoices[0].Distributor__c) {
            throw new WorkflowConflictException('A posted Primary Invoice is required.');
        }
        DMS_Invoice__c invoice = invoices[0];
        Warehouse__c warehouse = requireCompanyWarehouse(invoice.Warehouse__c);
        List<Order> orders = [
            SELECT Id, OrderNumber, AccountId, Type, Status, DMS_Approver__c
            FROM Order
            WHERE Id = :invoice.Secondary_Order__c
              AND AccountId = :invoice.Distributor__c
              AND Type = 'Primary Order' AND Status = 'Activated'
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty() || !hasApprovedProcess(orders[0].Id)) {
            throw new WorkflowConflictException('Only an approved Primary Order can be dispatched.');
        }
        if (orders[0].DMS_Approver__c == null || [
            SELECT Id FROM User
            WHERE Id = :orders[0].DMS_Approver__c AND IsActive = true
            LIMIT 1
        ].isEmpty()) {
            throw new WorkflowConflictException(
                'Assign an active Salesforce approver to the Primary Order before creating its dispatch.'
            );
        }
        List<Object> rawLines = payload.get('lines') instanceof List<Object>
            ? (List<Object>) payload.get('lines')
            : new List<Object>();
        if (rawLines.isEmpty()) throw new WorkflowRequestException('Add at least one dispatch line.');

        Map<Id, DMS_Invoice_Line__c> invoiceLineByOrderItem =
            new Map<Id, DMS_Invoice_Line__c>();
        for (DMS_Invoice_Line__c line : [
            SELECT Id, Order_Line_Item__c, Product__c, Product__r.Name,
                   Quantity__c, Unit_of_Measure__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
        ]) {
            invoiceLineByOrderItem.put(line.Order_Line_Item__c, line);
        }
        Map<Id, Decimal> requestedByOrderItem = new Map<Id, Decimal>();
        for (Object rawLine : rawLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                throw new WorkflowRequestException('Each dispatch line must contain an order item and quantity.');
            }
            Map<String, Object> lineInput = (Map<String, Object>) rawLine;
            Id orderItemId = parseId(lineInput.get('orderItemId'), OrderItem.SObjectType);
            Decimal quantity = parseDecimal(lineInput.get('quantity'));
            if (orderItemId == null || quantity == null || quantity <= 0
                || quantity != quantity.setScale(2, RoundingMode.DOWN)
                || requestedByOrderItem.containsKey(orderItemId)
                || !invoiceLineByOrderItem.containsKey(orderItemId)) {
                throw new WorkflowRequestException(
                    'Dispatch quantities must be positive, unique, and match invoice lines.'
                );
            }
            requestedByOrderItem.put(orderItemId, quantity);
        }

        Map<Id, Decimal> previouslyDispatched = dispatchedQuantities(invoice.Id, null);
        List<DMS_Dispatch_Line__c> linesToInsert = new List<DMS_Dispatch_Line__c>();
        Map<Id, Decimal> baseQuantityByProduct = new Map<Id, Decimal>();
        Map<Id, OrderItem> orderItems = new Map<Id, OrderItem>([
            SELECT Id, Product2Id, Unit_Conversion_Factor__c
            FROM OrderItem
            WHERE Id IN :requestedByOrderItem.keySet()
              AND OrderId = :orders[0].Id
        ]);
        if (orderItems.size() != requestedByOrderItem.size()) {
            throw new WorkflowConflictException('A dispatch line no longer matches the Primary Order.');
        }
        for (Id orderItemId : requestedByOrderItem.keySet()) {
            DMS_Invoice_Line__c invoiceLine = invoiceLineByOrderItem.get(orderItemId);
            Decimal prior = previouslyDispatched.containsKey(orderItemId)
                ? previouslyDispatched.get(orderItemId)
                : 0;
            Decimal quantity = requestedByOrderItem.get(orderItemId);
            if (prior + quantity > invoiceLine.Quantity__c) {
                throw new WorkflowConflictException(
                    'A dispatch quantity exceeds the remaining invoiced quantity.'
                );
            }
            OrderItem orderItem = orderItems.get(orderItemId);
            Decimal factor = orderItem.Unit_Conversion_Factor__c == null
                ? 1
                : orderItem.Unit_Conversion_Factor__c;
            if (factor <= 0) throw new WorkflowConflictException('The product unit conversion is invalid.');
            baseQuantityByProduct.put(
                orderItem.Product2Id,
                (baseQuantityByProduct.containsKey(orderItem.Product2Id)
                    ? baseQuantityByProduct.get(orderItem.Product2Id)
                    : 0) + quantity * factor
            );
            linesToInsert.add(new DMS_Dispatch_Line__c(
                Order_Line_Item__c = orderItemId,
                Product__c = invoiceLine.Product__c,
                Product_Name_Snapshot__c = invoiceLine.Product__r.Name,
                Quantity__c = quantity,
                Quantity_Delivered__c = 0,
                Quantity_Short__c = 0,
                Quantity_Damaged__c = 0,
                Unit_of_Measure__c = invoiceLine.Unit_of_Measure__c
            ));
        }
        validateCompanyStock(warehouse.Id, baseQuantityByProduct);

        DMS_Dispatch__c dispatch = new DMS_Dispatch__c(
            OwnerId = UserInfo.getUserId(),
            Distributor__c = invoice.Distributor__c,
            Invoice__c = invoice.Id,
            Order__c = orders[0].Id,
            Warehouse__c = warehouse.Id,
            Approver__c = orders[0].DMS_Approver__c,
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
        for (DMS_Dispatch_Line__c line : linesToInsert) line.Dispatch__c = dispatch.Id;
        insert linesToInsert;
        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'dispatchNumber' => dispatch.Name,
            'status' => dispatch.Status__c,
            'warehouseId' => warehouse.Id,
            'message' => 'Primary dispatch draft created. Submit it for Salesforce approval.'
        };
    }

    private static Map<String, Object> submitPrimaryDispatch(Map<String, Object> payload) {
        Id dispatchId = parseId(payload.get('dispatchId'), DMS_Dispatch__c.SObjectType);
        if (dispatchId == null) throw new WorkflowRequestException('A valid dispatch ID is required.');
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Name, Status__c, Approver__c, Order__c, Order__r.Type,
                   Invoice__c, Distributor__c, Warehouse__c
            FROM DMS_Dispatch__c WHERE Id = :dispatchId LIMIT 1 FOR UPDATE
        ];
        if (dispatches.isEmpty() || !isPrimaryDispatch(dispatches[0])) {
            throw new WorkflowConflictException('The requested Primary Dispatch is unavailable.');
        }
        DMS_Dispatch__c dispatch = dispatches[0];
        String approvalStatus = approvalStatusFor(dispatch.Id);
        if (approvalStatus == 'Pending' || approvalStatus == 'Approved') {
            return new Map<String, Object>{
                'dispatchId' => dispatch.Id,
                'status' => approvalStatus,
                'alreadyProcessed' => true
            };
        }
        if (dispatch.Status__c != 'Draft' || dispatch.Approver__c == null) {
            throw new WorkflowConflictException(
                'Only a Draft Primary Dispatch with an assigned approver can be submitted.'
            );
        }
        Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
        request.setObjectId(dispatch.Id);
        request.setSubmitterId(String.valueOf(dispatch.OwnerId));
        request.setComments('Primary dispatch submitted by an authorized company operator.');
        Approval.ProcessResult result = Approval.process(request);
        if (!result.isSuccess()) {
            List<String> messages = new List<String>();
            for (Database.Error error : result.getErrors()) messages.add(error.getMessage());
            throw new WorkflowConflictException(messages.isEmpty()
                ? 'Salesforce did not submit the Primary Dispatch for approval.'
                : 'Dispatch approval submission failed: ' + String.join(messages, ' '));
        }
        if (approvalStatusFor(dispatch.Id) != 'Pending') {
            throw new WorkflowConflictException('Salesforce did not confirm pending dispatch approval.');
        }
        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'status' => 'Submitted'
        };
    }

    private static Map<String, Object> confirmPrimaryDispatch(Map<String, Object> payload) {
        Id dispatchId = parseId(payload.get('dispatchId'), DMS_Dispatch__c.SObjectType);
        if (dispatchId == null) throw new WorkflowRequestException('A valid dispatch ID is required.');
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Name, Invoice__c, Order__c, Order__r.Type, Order__r.Status,
                   Distributor__c, Warehouse__c, Status__c, Delivery_Status__c,
                   Actual_Dispatch_Date__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
            LIMIT 1
            FOR UPDATE
        ];
        if (dispatches.isEmpty() || !isPrimaryDispatch(dispatches[0])) {
            throw new WorkflowConflictException('The requested Primary Dispatch is unavailable.');
        }
        DMS_Dispatch__c dispatch = dispatches[0];
        if (dispatch.Status__c == 'Dispatched'
            || dispatch.Status__c == 'Partially Delivered'
            || dispatch.Status__c == 'Delivered') {
            verifyPriorCompanyDispatchStock(dispatch);
            return new Map<String, Object>{
                'dispatchId' => dispatch.Id,
                'status' => dispatch.Status__c,
                'alreadyProcessed' => true
            };
        }
        if (dispatch.Status__c != 'Draft' && dispatch.Status__c != 'Submitted'
            && dispatch.Status__c != 'Approved') {
            throw new WorkflowConflictException('This Primary Dispatch cannot be confirmed in its current status.');
        }
        if (approvalStatusFor(dispatch.Id) != 'Approved') {
            throw new WorkflowConflictException(
                'The Primary Dispatch must be approved in Salesforce before it can be confirmed.'
            );
        }
        List<DMS_Invoice__c> invoices = [
            SELECT Id, Status__c, Distributor__c, Warehouse__c
            FROM DMS_Invoice__c
            WHERE Id = :dispatch.Invoice__c
            LIMIT 1
            FOR UPDATE
        ];
        if (invoices.isEmpty() || invoices[0].Status__c != 'Posted'
            || invoices[0].Distributor__c != dispatch.Distributor__c
            || invoices[0].Warehouse__c != dispatch.Warehouse__c) {
            throw new WorkflowConflictException('The posted invoice does not match this dispatch.');
        }
        DMS_Invoice__c invoice = invoices[0];
        List<Order> orders = [
            SELECT Id, AccountId, Type, Status
            FROM Order
            WHERE Id = :dispatch.Order__c
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty() || orders[0].Type != 'Primary Order'
            || orders[0].Status != 'Activated'
            || orders[0].AccountId != dispatch.Distributor__c
            || !hasApprovedProcess(orders[0].Id)) {
            throw new WorkflowConflictException('The Primary Order is not approved and activated.');
        }
        Warehouse__c warehouse = requireCompanyWarehouse(dispatch.Warehouse__c);
        List<DMS_Dispatch_Line__c> lines = [
            SELECT Id, Order_Line_Item__c, Product__c, Quantity__c,
                   Order_Line_Item__r.Product2Id,
                   Order_Line_Item__r.Unit_Conversion_Factor__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
            FOR UPDATE
        ];
        if (lines.isEmpty()) throw new WorkflowConflictException('The dispatch has no lines.');

        Map<Id, Decimal> allocatedQuantities = dispatchedQuantities(invoice.Id, null);
        Map<Id, Decimal> invoicedQuantities = new Map<Id, Decimal>();
        for (DMS_Invoice_Line__c invoiceLine : [
            SELECT Order_Line_Item__c, Quantity__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
        ]) {
            invoicedQuantities.put(invoiceLine.Order_Line_Item__c, invoiceLine.Quantity__c);
        }
        for (Id orderItemId : allocatedQuantities.keySet()) {
            if (!invoicedQuantities.containsKey(orderItemId)
                || allocatedQuantities.get(orderItemId) > invoicedQuantities.get(orderItemId)) {
                throw new WorkflowConflictException(
                    'Dispatch quantities exceed the remaining posted invoice quantities.'
                );
            }
        }

        Map<Id, Decimal> quantityByProduct = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c line : lines) {
            if (line.Product__c == null || line.Product__c != line.Order_Line_Item__r.Product2Id
                || line.Quantity__c == null || line.Quantity__c <= 0) {
                throw new WorkflowConflictException('A dispatch line has an invalid product or quantity.');
            }
            Decimal factor = line.Order_Line_Item__r.Unit_Conversion_Factor__c == null
                ? 1
                : line.Order_Line_Item__r.Unit_Conversion_Factor__c;
            if (factor <= 0) throw new WorkflowConflictException('A dispatch line has an invalid unit conversion.');
            quantityByProduct.put(
                line.Product__c,
                (quantityByProduct.containsKey(line.Product__c)
                    ? quantityByProduct.get(line.Product__c)
                    : 0) + line.Quantity__c * factor
            );
        }
        Map<Id, Inventory__c> balances =
            validateCompanyStock(warehouse.Id, quantityByProduct);
        List<Inventory_Transaction__c> transactions =
            new List<Inventory_Transaction__c>();
        for (Id productId : quantityByProduct.keySet()) {
            Inventory__c balance = balances.get(productId);
            Decimal quantity = quantityByProduct.get(productId);
            balance.Available_Quantity__c -= quantity;
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = balance.Id,
                Transaction_Type__c = 'Primary Order Sale',
                Quantity__c = quantity,
                Transaction_Date__c = System.now(),
                Reference_Number__c = dispatch.Name + '-' + String.valueOf(productId),
                Transaction_Description__c = 'Company stock deducted at Primary Dispatch confirmation',
                DMS_Invoice__c = dispatch.Invoice__c,
                DMS_Dispatch__c = dispatch.Id
            ));
        }
        update balances.values();
        insert transactions;
        dispatch.Status__c = 'Dispatched';
        dispatch.Delivery_Status__c = 'In Transit';
        dispatch.Actual_Dispatch_Date__c = System.now();
        update dispatch;
        Map<Id, Decimal> shippedQuantities = confirmedDispatchedQuantities(invoice.Id);
        Boolean invoiceFullyDispatched = true;
        for (DMS_Invoice_Line__c invoiceLine : [
            SELECT Order_Line_Item__c, Quantity__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
        ]) {
            if ((shippedQuantities.containsKey(invoiceLine.Order_Line_Item__c)
                    ? shippedQuantities.get(invoiceLine.Order_Line_Item__c)
                    : 0) < invoiceLine.Quantity__c) {
                invoiceFullyDispatched = false;
                break;
            }
        }
        invoice.Stock_Deduction_Status__c = invoiceFullyDispatched
            ? 'Deducted at Dispatch'
            : 'Partially Dispatched';
        update invoice;
        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'dispatchNumber' => dispatch.Name,
            'status' => dispatch.Status__c,
            'deliveryStatus' => dispatch.Delivery_Status__c,
            'message' => 'Company stock was deducted for the confirmed Primary Dispatch.'
        };
    }

    private static Map<String, Object> updatePrimaryDelivery(Map<String, Object> payload) {
        Id dispatchId = parseId(payload.get('dispatchId'), DMS_Dispatch__c.SObjectType);
        if (dispatchId == null) throw new WorkflowRequestException('A valid dispatch ID is required.');
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Name, Status__c, Delivery_Status__c, Order__r.Type,
                   Warehouse__c, Tracking_Number__c, Transporter_Name__c,
                   Vehicle_Number__c, Expected_Delivery_Date__c,
                   Actual_Delivery_Date__c, Delivery_Remarks__c
            FROM DMS_Dispatch__c WHERE Id = :dispatchId LIMIT 1 FOR UPDATE
        ];
        if (dispatches.isEmpty() || !isPrimaryDispatch(dispatches[0])) {
            throw new WorkflowConflictException('The requested Primary Dispatch is unavailable.');
        }
        DMS_Dispatch__c dispatch = dispatches[0];
        if (dispatch.Status__c != 'Dispatched'
            && dispatch.Status__c != 'Partially Delivered'
            && dispatch.Status__c != 'Delivered') {
            throw new WorkflowConflictException('Only a confirmed Primary Dispatch can receive delivery updates.');
        }
        if (payload.containsKey('trackingNumber')) {
            dispatch.Tracking_Number__c = stringValue(payload.get('trackingNumber'));
        }
        if (payload.containsKey('transporterName')) {
            dispatch.Transporter_Name__c = stringValue(payload.get('transporterName'));
        }
        if (payload.containsKey('vehicleNumber')) {
            dispatch.Vehicle_Number__c = stringValue(payload.get('vehicleNumber'));
        }
        if (payload.containsKey('expectedDeliveryDate')) {
            dispatch.Expected_Delivery_Date__c = parseDate(payload.get('expectedDeliveryDate'));
        }
        if (payload.containsKey('actualDeliveryDate')) {
            dispatch.Actual_Delivery_Date__c = parseDate(payload.get('actualDeliveryDate'));
        }
        if (payload.containsKey('deliveryStatus')) {
            String deliveryStatus = stringValue(payload.get('deliveryStatus'));
            if (!new Set<String>{
                'In Transit', 'Partially Delivered', 'Delivered',
                'Failed', 'Rescheduled', 'Returned to Sender'
            }.contains(deliveryStatus)) {
                throw new WorkflowRequestException('Select a valid delivery status.');
            }
            dispatch.Delivery_Status__c = deliveryStatus;
        }
        if (payload.containsKey('deliveryRemarks')) {
            dispatch.Delivery_Remarks__c = stringValue(payload.get('deliveryRemarks'));
        }
        update dispatch;
        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'status' => dispatch.Status__c,
            'deliveryStatus' => dispatch.Delivery_Status__c,
            'message' => 'Delivery details updated. Inventory was not changed.'
        };
    }

    private static Map<Id, Inventory__c> validateCompanyStock(
        Id warehouseId,
        Map<Id, Decimal> quantitiesByProduct
    ) {
        Map<Id, Inventory__c> balancesByProduct = new Map<Id, Inventory__c>();
        List<Inventory__c> balances = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId AND Product__c IN :quantitiesByProduct.keySet()
            FOR UPDATE
        ];
        for (Inventory__c balance : balances) {
            if (balancesByProduct.containsKey(balance.Product__c)) {
                throw new WorkflowConflictException(
                    'Duplicate inventory balances exist for a product and Company Warehouse.'
                );
            }
            balancesByProduct.put(balance.Product__c, balance);
        }
        for (Id productId : quantitiesByProduct.keySet()) {
            Inventory__c balance = balancesByProduct.get(productId);
            if (balance == null) {
                throw new WorkflowConflictException(
                    'A company inventory balance is missing for a dispatch product.'
                );
            }
            Decimal available = balance.Available_Quantity__c == null
                ? 0
                : balance.Available_Quantity__c;
            Decimal reserved = balance.Reserved_Quantity__c == null
                ? 0
                : balance.Reserved_Quantity__c;
            if (available < quantitiesByProduct.get(productId) || available < 0 || reserved < 0) {
                throw new WorkflowConflictException(
                    'Company available stock is insufficient for the requested dispatch.'
                );
            }
        }
        return balancesByProduct;
    }

    private static void verifyPriorCompanyDispatchStock(DMS_Dispatch__c dispatch) {
        Map<Id, Decimal> expectedByProduct = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c line : [
            SELECT Product__c, Quantity__c,
                   Order_Line_Item__r.Unit_Conversion_Factor__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
        ]) {
            Decimal factor = line.Order_Line_Item__r.Unit_Conversion_Factor__c == null
                ? 1
                : line.Order_Line_Item__r.Unit_Conversion_Factor__c;
            expectedByProduct.put(
                line.Product__c,
                (expectedByProduct.containsKey(line.Product__c)
                    ? expectedByProduct.get(line.Product__c)
                    : 0) + line.Quantity__c * factor
            );
        }

        Map<Id, Decimal> actualByProduct = new Map<Id, Decimal>();
        for (Inventory_Transaction__c stockTransaction : [
            SELECT Inventory__r.Product__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE DMS_Dispatch__c = :dispatch.Id
              AND Transaction_Type__c = 'Primary Order Sale'
        ]) {
            Id productId = stockTransaction.Inventory__r.Product__c;
            actualByProduct.put(
                productId,
                (actualByProduct.containsKey(productId) ? actualByProduct.get(productId) : 0)
                    + stockTransaction.Quantity__c
            );
        }
        if (expectedByProduct.isEmpty() || !sameQuantities(expectedByProduct, actualByProduct)) {
            throw new WorkflowConflictException(
                'Dispatch stock transactions do not match this confirmed dispatch. Contact an administrator.'
            );
        }
    }

    private static Map<Id, Decimal> confirmedDispatchedQuantities(Id invoiceId) {
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        Set<String> confirmedStatuses = new Set<String>{
            'Dispatched', 'Partially Delivered', 'Delivered'
        };
        for (DMS_Dispatch_Line__c line : [
            SELECT Order_Line_Item__c, Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__r.Invoice__c = :invoiceId
              AND Dispatch__r.Status__c IN :confirmedStatuses
        ]) {
            Id orderItemId = line.Order_Line_Item__c;
            totals.put(
                orderItemId,
                (totals.containsKey(orderItemId) ? totals.get(orderItemId) : 0)
                    + line.Quantity__c
            );
        }
        return totals;
    }

    private static Map<Id, Decimal> dispatchedQuantities(Id invoiceId, Id exceptDispatchId) {
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c line : [
            SELECT Dispatch__c, Order_Line_Item__c, Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__r.Invoice__c = :invoiceId
              AND Dispatch__r.Status__c IN :ACTIVE_DISPATCH_STATUSES
            ORDER BY CreatedDate, Id
        ]) {
            if (exceptDispatchId != null && line.Dispatch__c == exceptDispatchId) continue;
            Id orderItemId = line.Order_Line_Item__c;
            totals.put(
                orderItemId,
                (totals.containsKey(orderItemId) ? totals.get(orderItemId) : 0)
                    + line.Quantity__c
            );
        }
        return totals;
    }

    private static void validateRetryLines(Id dispatchId, Object rawLines) {
        List<Object> requested = rawLines instanceof List<Object>
            ? (List<Object>) rawLines
            : new List<Object>();
        Map<Id, Decimal> requestedByItem = new Map<Id, Decimal>();
        for (Object rawLine : requested) {
            if (!(rawLine instanceof Map<String, Object>)) {
                throw new WorkflowConflictException('The retry payload does not match the saved dispatch.');
            }
            Map<String, Object> lineInput = (Map<String, Object>) rawLine;
            Id itemId = parseId(lineInput.get('orderItemId'), OrderItem.SObjectType);
            Decimal quantity = parseDecimal(lineInput.get('quantity'));
            if (itemId == null || quantity == null || requestedByItem.containsKey(itemId)) {
                throw new WorkflowConflictException('The retry payload does not match the saved dispatch.');
            }
            requestedByItem.put(itemId, quantity);
        }
        Map<Id, Decimal> savedByItem = new Map<Id, Decimal>();
        for (DMS_Dispatch_Line__c line : [
            SELECT Order_Line_Item__c, Quantity__c
            FROM DMS_Dispatch_Line__c WHERE Dispatch__c = :dispatchId
        ]) {
            savedByItem.put(line.Order_Line_Item__c, line.Quantity__c);
        }
        if (!sameQuantities(requestedByItem, savedByItem)) {
            throw new WorkflowConflictException('The retry payload differs from the saved dispatch lines.');
        }
    }

    private static Boolean sameQuantities(Map<Id, Decimal> left, Map<Id, Decimal> right) {
        if (left.size() != right.size()) return false;
        for (Id key : left.keySet()) {
            if (!right.containsKey(key) || left.get(key) != right.get(key)) return false;
        }
        return true;
    }

    private static Warehouse__c requireCompanyWarehouse(Id warehouseId) {
        if (warehouseId == null) {
            throw new WorkflowRequestException('Select a Company Warehouse.');
        }
        List<Warehouse__c> warehouses = [
            SELECT Id, Name, Warehouse_Type__c, Distributor__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouseId
            LIMIT 1
            FOR UPDATE
        ];
        if (warehouses.isEmpty()
            || warehouses[0].Warehouse_Type__c != COMPANY_WAREHOUSE
            || warehouses[0].Distributor__c != null
            || warehouses[0].Warehouse_Status__c != 'Active') {
            throw new WorkflowConflictException(
                'Select an active Company Warehouse with no distributor owner.'
            );
        }
        return warehouses[0];
    }

    private static Boolean isPrimaryDispatch(DMS_Dispatch__c dispatch) {
        return dispatch.Order__r != null && dispatch.Order__r.Type == 'Primary Order';
    }

    private static Boolean hasApprovedProcess(Id recordId) {
        return ![
            SELECT Id
            FROM ProcessInstance
            WHERE TargetObjectId = :recordId AND Status = 'Approved'
            LIMIT 1
        ].isEmpty();
    }

    private static String approvalStatusFor(Id recordId) {
        List<ProcessInstance> processes = [
            SELECT Status
            FROM ProcessInstance
            WHERE TargetObjectId = :recordId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return processes.isEmpty() ? null : processes[0].Status;
    }

    private static Map<String, Object> invoiceResponse(DMS_Invoice__c invoice, Boolean alreadyProcessed) {
        return new Map<String, Object>{
            'invoiceId' => invoice.Id,
            'invoiceNumber' => invoice.Name,
            'orderId' => invoice.Secondary_Order__c,
            'warehouseId' => invoice.Warehouse__c,
            'status' => invoice.Status__c,
            'alreadyProcessed' => alreadyProcessed,
            'message' => alreadyProcessed
                ? 'This Primary Invoice request was already processed.'
                : 'Primary Invoice draft created. Posting it does not change stock.'
        };
    }

    private static Boolean isCompanyOperator() {
        return UserInfo.getUserType() != 'Guest'
            && FeatureManagement.checkPermission(COMPANY_PERMISSION);
    }

    private static Id parseId(Object value, Schema.SObjectType expectedType) {
        if (value == null) return null;
        try {
            Id parsed = Id.valueOf(String.valueOf(value));
            return parsed.getSObjectType() == expectedType ? parsed : null;
        } catch (Exception error) {
            return null;
        }
    }

    private static Decimal parseDecimal(Object value) {
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
            throw new WorkflowRequestException('Enter a valid ISO date.');
        }
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static void writeResponse(RestResponse response, Integer statusCode, Object body) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static void logFailure(String description, Exception error) {
        System.debug(LoggingLevel.ERROR,
            description + ': ' + error.getTypeName() + ': ' + error.getMessage()
            + '\n' + error.getStackTraceString());
    }

    private class WorkflowRequestException extends Exception {}
    private class WorkflowConflictException extends Exception {}
}
