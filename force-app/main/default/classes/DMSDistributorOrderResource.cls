@RestResource(urlMapping='/dms/v1/orders/*')
global without sharing class DMSDistributorOrderResource {
    private static final Integer HISTORY_PAGE_SIZE = 100;
    private static final Integer MAX_ORDER_LINES = 100;
    private static final Decimal MAX_ORDER_QUANTITY = 1000000000;

    @HttpGet
    global static void getOrders() {
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
            String orderIdValue = getParameter('orderId');
            if (String.isNotBlank(orderIdValue)) {
                Id orderId = parseId(orderIdValue);
                writeResponse(response, 200, new Map<String, Object>{
                    'success' => true,
                    'order' => getOrderDetails(distributor, orderId)
                });
                return;
            }

            String salesType = normalizeSalesType(getParameter('type'));
            if (salesType == null) {
                throw new RequestException('Select Primary or Secondary sales.');
            }
            String view = getParameter('view');
            if (view == 'catalog') {
                writeResponse(response, 200, getCatalog(distributor, salesType));
            } else if (view == 'history') {
                Datetime cursorCreatedAt;
                Id cursorId;
                String cursorTimestampValue = getParameter('cursorCreatedAt');
                String cursorIdValue = getParameter('cursorId');
                if (String.isNotBlank(cursorTimestampValue)
                    || String.isNotBlank(cursorIdValue)) {
                    if (String.isBlank(cursorTimestampValue) || String.isBlank(cursorIdValue)) {
                        throw new RequestException('The order history cursor is invalid.');
                    }
                    try {
                        cursorCreatedAt = Datetime.newInstance(Long.valueOf(cursorTimestampValue));
                    } catch (Exception error) {
                        throw new RequestException('The order history cursor is invalid.');
                    }
                    cursorId = parseId(cursorIdValue);
                    if (cursorId.getSObjectType() != Order.SObjectType) {
                        throw new RequestException('The order history cursor is invalid.');
                    }
                }
                writeResponse(response, 200, getHistory(
                    distributor,
                    salesType,
                    cursorCreatedAt,
                    cursorId
                ));
            } else {
                throw new RequestException('Select a valid order view.');
            }
        } catch (ConflictException error) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (RequestException error) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (Exception error) {
            System.debug(LoggingLevel.ERROR,
                'DMS order query failed: ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'Order data could not be loaded. Please try again.'
            });
        }
    }

    @HttpPost
    global static void postOrder() {
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

        Map<String, Object> payload = readPayload();
        if (payload == null) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'A valid JSON request body is required.'
            });
            return;
        }

        try {
            String action = stringValue(payload.get('action'));
            if (action == 'findWarehouses' || action == 'allocateStock'
                || action == 'validateStock' || action == 'reserveStock'
                || action == 'releaseStockReservation'
                || action == 'reservationStatus') {
                performStockAction(distributor, payload, action, response);
                return;
            }
            String salesType = normalizeSalesType(stringValue(payload.get('salesType')));
            if (salesType == null) {
                throw new RequestException('Select Primary or Secondary sales.');
            }
            if (action == 'submitForApproval') {
                submitOrderForApproval(distributor, payload, salesType, response);
                return;
            }
            if (action != 'preview' && action != 'create') {
                throw new RequestException('The requested order action is not supported.');
            }
            Id retailerId = parseOptionalId(payload.get('retailerId'));
            String requestKey;
            if (action == 'create') {
                requestKey = stringValue(payload.get('requestKey'));
                if (String.isBlank(requestKey) || requestKey.length() > 80) {
                    throw new RequestException('A request key of 1 to 80 characters is required.');
                }
                Order existingOrder = findOrderByRequestKey(requestKey);
                if (existingOrder != null) {
                    if (existingOrder.AccountId != distributor.Id
                        || existingOrder.Type != orderType(salesType)) {
                        throw new ConflictException('This request key is already in use.');
                    }
                    writeResponse(response, 200, new Map<String, Object>{
                        'success' => true,
                        'order' => getOrderDetails(distributor, existingOrder.Id),
                        'message' => 'This order was already created.'
                    });
                    return;
                }
            }

            OrderCalculation calculation = calculateOrder(
                distributor,
                salesType,
                retailerId,
                payload.get('lines'),
                payload.get('selectedSchemeProductIds')
            );
            if (action == 'preview') {
                writeResponse(response, 200, new Map<String, Object>{
                    'success' => true,
                    'preview' => calculation.preview
                });
                return;
            }

            Savepoint savepoint = Database.setSavepoint();
            try {
                Order salesOrder = new Order(
                    AccountId = distributor.Id,
                    Outlet__c = retailerId,
                    Type = orderType(salesType),
                    Status = 'Draft',
                    EffectiveDate = Date.today(),
                    Pricebook2Id = calculation.pricebookId,
                    DMS_Request_Key__c = requestKey
                );
                insert salesOrder;

                List<OrderItem> orderItems = new List<OrderItem>();
                for (CalculatedLine line : calculation.lines) {
                    if (line.paidQuantity > 0) {
                        orderItems.add(buildOrderItem(
                            salesOrder.Id,
                            line,
                            line.paidQuantity,
                            line.paidQuantity,
                            0,
                            line.paidUnitPrice,
                            line.taxAmount
                        ));
                    }
                    if (line.freeQuantity > 0) {
                        orderItems.add(buildOrderItem(
                            salesOrder.Id,
                            line,
                            line.freeQuantity,
                            0,
                            line.freeQuantity,
                            0,
                            0
                        ));
                    }
                }
                insert orderItems;

                List<Order_Scheme__c> appliedSchemes = new List<Order_Scheme__c>();
                for (CalculatedLine line : calculation.lines) {
                    if (line.scheme != null) {
                        appliedSchemes.add(new Order_Scheme__c(
                            Order__c = salesOrder.Id,
                            Scheme__c = line.scheme.Scheme__c,
                            Scheme_Product__c = line.scheme.Id,
                            Applied_Quantity__c = line.paidQuantity,
                            Free_Quantity__c = line.freeQuantity,
                            Discount_Amount__c = line.schemeDiscountAmount,
                            Status__c = 'Applied'
                        ));
                    }
                }
                if (!appliedSchemes.isEmpty()) {
                    insert appliedSchemes;
                }

                if (salesType == 'Secondary') {
                    salesOrder.Status = 'Activated';
                    update salesOrder;
                }

                writeResponse(response, 201, new Map<String, Object>{
                    'success' => true,
                    'order' => getOrderDetails(distributor, salesOrder.Id)
                });
            } catch (DmlException error) {
                Database.rollback(savepoint);
                Order duplicate = findOrderByRequestKey(requestKey);
                if (duplicate != null && duplicate.AccountId == distributor.Id
                    && duplicate.Type == orderType(salesType)) {
                    writeResponse(response, 200, new Map<String, Object>{
                        'success' => true,
                        'order' => getOrderDetails(distributor, duplicate.Id),
                        'message' => 'This order was already created.'
                    });
                    return;
                }
                System.debug(LoggingLevel.ERROR,
                    'DMS order insert failed: ' + error.getMessage() +
                    '\n' + error.getStackTraceString());
                writeResponse(response, 400, new Map<String, Object>{
                    'success' => false,
                    'message' => 'The order could not be saved. Check the configured order and product data.'
                });
            } catch (Exception error) {
                Database.rollback(savepoint);
                throw error;
            }
        } catch (ConflictException error) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (ReservationAccessException error) {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (RequestException error) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (ConfigurationException error) {
            writeResponse(response, 503, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (Exception error) {
            System.debug(LoggingLevel.ERROR,
                'DMS order operation failed: ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The order could not be processed. Please try again.'
            });
        }
    }

    private static Map<String, Object> getCatalog(Account distributor, String salesType) {
        Pricebook2 pricebook = getChannelPricebook(salesType);
        List<PricebookEntry> entries = [
            SELECT Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode,
                   Product2.Description, Product2.DisplayUrl, Product2.IsActive,
                   Product2.SFA_Product__c, Product2.DMS_Tax_Rate__c,
                   Product2.QuantityUnitOfMeasure, Pricebook2.Name,
                   Unit_of_Measure__c, Unit_Conversion_Factor__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebook.Id
              AND IsActive = true
              AND Product2.IsActive = true
              AND Product2.SFA_Product__c = true
            ORDER BY Product2.Name
        ];

        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry entry : entries) {
            productIds.add(entry.Product2Id);
        }
        Map<Id, Map<String, Decimal>> unitFactors = getUnitFactors(productIds);
        List<Map<String, Object>> products = new List<Map<String, Object>>();
        for (PricebookEntry entry : entries) {
            validatePricebookEntry(entry);
            products.add(productSummary(entry, unitFactors.get(entry.Product2Id)));
        }

        List<Map<String, Object>> schemes = new List<Map<String, Object>>();
        for (List<Scheme_Product__c> productSchemes : getActiveSchemes(productIds, salesType).values()) {
            for (Scheme_Product__c scheme : productSchemes) {
                schemes.add(schemeSummary(scheme));
            }
        }

        List<Map<String, Object>> retailers = new List<Map<String, Object>>();
        if (salesType == 'Secondary') {
            for (Account retailer : [
                SELECT Id, Name, Phone, BillingCity, BillingState
                FROM Account
                WHERE Distributor__c = :distributor.Id
                  AND Account_Category__c = 'Outlet'
                  AND Active__c = 'Yes'
                ORDER BY Name
            ]) {
                retailers.add(new Map<String, Object>{
                    'id' => retailer.Id,
                    'name' => retailer.Name,
                    'phone' => retailer.Phone,
                    'city' => retailer.BillingCity,
                    'state' => retailer.BillingState
                });
            }
        }

        List<Map<String, Object>> warehouses = new List<Map<String, Object>>();
        for (Warehouse__c warehouse : [
            SELECT Id, Name
            FROM Warehouse__c
            WHERE Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
              AND Warehouse_Status__c = 'Active'
            ORDER BY Name
            LIMIT 200
        ]) {
            warehouses.add(new Map<String, Object>{
                'id' => warehouse.Id,
                'name' => warehouse.Name
            });
        }

        return new Map<String, Object>{
            'success' => true,
            'salesType' => salesType,
            'customer' => new Map<String, Object>{
                'id' => distributor.Id,
                'name' => distributor.Name
            },
            'retailers' => retailers,
            'warehouses' => warehouses,
            'products' => products,
            'schemes' => schemes
        };
    }

    private static Map<String, Object> getHistory(
        Account distributor,
        String salesType,
        Datetime cursorCreatedAt,
        Id cursorId
    ) {
        String selectedOrderType = orderType(salesType);
        Id distributorId = distributor.Id;
        Integer queryLimit = HISTORY_PAGE_SIZE + 1;
        String query = 'SELECT Id, OrderNumber, Type, Status, EffectiveDate, TotalAmount, '
            + 'AccountId, Account.Name, Outlet__c, Outlet__r.Name, Owner.Name, CreatedDate, '
            + 'DMS_Approver__c, DMS_Approver__r.Name, DMS_Fulfillment_Warehouse__c, '
            + 'DMS_Fulfillment_Warehouse__r.Name, DMS_Allocation_Status__c '
            + 'FROM Order WHERE AccountId = :distributorId AND Type = :selectedOrderType ';
        if (cursorCreatedAt != null && cursorId != null) {
            query += 'AND (CreatedDate < :cursorCreatedAt OR '
                + '(CreatedDate = :cursorCreatedAt AND Id < :cursorId)) ';
        }
        query += 'ORDER BY CreatedDate DESC, Id DESC LIMIT :queryLimit';
        List<Order> historyRecords = Database.query(query);
        Boolean hasMore = historyRecords.size() > HISTORY_PAGE_SIZE;
        List<Map<String, Object>> orders = new List<Map<String, Object>>();
        Set<Id> orderIds = new Set<Id>();
        for (Integer index = 0; index < historyRecords.size() && index < HISTORY_PAGE_SIZE; index++) {
            orderIds.add(historyRecords[index].Id);
        }
        Map<Id, Map<String, Object>> approvalSummaries = getApprovalSummaries(orderIds);
        Map<Id, Map<String, Object>> invoiceSummaries =
            getInvoiceSummaries(orderIds, distributor.Id);
        Map<Id, Map<String, Object>> dispatchSummaries =
            getLatestDispatchSummaries(orderIds, distributor.Id);
        Map<Id, Map<String, Object>> goodsReceiptSummaries =
            getLatestGoodsReceiptSummaries(orderIds, distributor.Id);
        Map<Id, List<Map<String, Object>>> allocationSummaries =
            getAllocationSummaries(orderIds);
        Set<Id> fulfilledOrderIds = getOrdersWithPostedInvoices(orderIds);
        for (Integer index = 0; index < historyRecords.size() && index < HISTORY_PAGE_SIZE; index++) {
            Order historyOrder = historyRecords[index];
            Map<String, Object> summary = orderSummary(historyOrder);
            summary.putAll(approvalSummaries.get(historyOrder.Id));
            if (invoiceSummaries.containsKey(historyOrder.Id)) {
                summary.putAll(invoiceSummaries.get(historyOrder.Id));
            }
            if (dispatchSummaries.containsKey(historyOrder.Id)) {
                summary.putAll(dispatchSummaries.get(historyOrder.Id));
            }
            if (goodsReceiptSummaries.containsKey(historyOrder.Id)) {
                summary.putAll(goodsReceiptSummaries.get(historyOrder.Id));
            }
            summary.put('allocationLines', allocationSummaries.get(historyOrder.Id));
            summary.put('fulfillmentStatus', fulfilledOrderIds.contains(historyOrder.Id)
                ? 'Consumed'
                : 'Not Fulfilled');
            orders.add(summary);
        }
        Order lastOrder = orders.isEmpty()
            ? null
            : historyRecords[orders.size() - 1];
        return new Map<String, Object>{
            'success' => true,
            'salesType' => salesType,
            'orders' => orders,
            'hasMore' => hasMore,
            'nextCursor' => hasMore && lastOrder != null
                ? new Map<String, Object>{
                    'createdAt' => lastOrder.CreatedDate.getTime(),
                    'id' => lastOrder.Id
                }
                : null,
            'pageSize' => HISTORY_PAGE_SIZE
        };
    }

    private static Map<String, Object> getOrderDetails(Account distributor, Id orderId) {
        List<Order> matches = [
            SELECT Id, OrderNumber, Type, Status, EffectiveDate, TotalAmount,
                   AccountId, Account.Name, Outlet__c, Outlet__r.Name, Owner.Name, CreatedDate,
                   DMS_Approver__c, DMS_Approver__r.Name, DMS_Fulfillment_Warehouse__c,
                   DMS_Fulfillment_Warehouse__r.Name, DMS_Allocation_Status__c
            FROM Order
            WHERE Id = :orderId
              AND AccountId = :distributor.Id
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new RequestException('The requested order is not available to this distributor.');
        }

        Order salesOrder = matches[0];
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        Map<Id, Order_Scheme__c> appliedSchemesByProduct = new Map<Id, Order_Scheme__c>();
        for (Order_Scheme__c appliedScheme : [
            SELECT Id, Scheme__c, Scheme__r.Scheme_Name__c,
                   Scheme_Product__r.Product__c, Applied_Quantity__c,
                   Free_Quantity__c, Discount_Amount__c
            FROM Order_Scheme__c
            WHERE Order__c = :salesOrder.Id
              AND Status__c = 'Applied'
            ORDER BY CreatedDate, Id
        ]) {
            Id appliedProductId = appliedScheme.Scheme_Product__r == null
                ? null
                : appliedScheme.Scheme_Product__r.Product__c;
            if (appliedProductId != null && !appliedSchemesByProduct.containsKey(appliedProductId)) {
                appliedSchemesByProduct.put(appliedProductId, appliedScheme);
            }
        }
        Decimal taxTotal = 0;
        Boolean hasTaxSnapshots = true;
        for (OrderItem item : [
            SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, ListPrice,
                   TotalPrice, DMS_List_Price__c, Paid_Quantity__c, Free_Quantity__c, Unit_of_Measure__c,
                   Unit_Conversion_Factor__c,
                   DMS_Tax_Rate__c, DMS_Tax_Amount__c
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ]) {
            Decimal listPrice = item.DMS_List_Price__c == null
                ? item.ListPrice
                : item.DMS_List_Price__c;
            Decimal discount = listPrice == null || item.UnitPrice == null
                ? null
                : ((listPrice - item.UnitPrice) * item.Quantity).setScale(2);
            Decimal lineTax = item.DMS_Tax_Amount__c;
            if (lineTax == null) {
                hasTaxSnapshots = false;
            } else {
                taxTotal += lineTax;
            }
            Order_Scheme__c appliedScheme = appliedSchemesByProduct.get(item.Product2Id);
            lines.add(new Map<String, Object>{
                'id' => item.Id,
                'productId' => item.Product2Id,
                'productName' => item.Product2 == null ? null : item.Product2.Name,
                'quantity' => item.Quantity,
                'paidQuantity' => item.Paid_Quantity__c,
                'freeQuantity' => item.Free_Quantity__c,
                'listPrice' => listPrice,
                'unitPrice' => item.UnitPrice,
                'unitOfMeasure' => item.Unit_of_Measure__c,
                'conversionFactor' => item.Unit_Conversion_Factor__c,
                'discountAmount' => discount,
                'taxRate' => item.DMS_Tax_Rate__c,
                'taxAmount' => lineTax,
                'lineTotal' => item.TotalPrice,
                'schemeId' => appliedScheme == null ? null : appliedScheme.Scheme__c,
                'schemeName' => appliedScheme == null || appliedScheme.Scheme__r == null
                    ? null
                    : appliedScheme.Scheme__r.Scheme_Name__c
            });
        }

        Map<String, Object> summary = orderSummary(salesOrder);
        summary.putAll(getApprovalSummaries(new Set<Id>{salesOrder.Id}).get(salesOrder.Id));
        summary.put(
            'allocationLines',
            getAllocationSummaries(new Set<Id>{salesOrder.Id}).get(salesOrder.Id)
        );
        summary.put('fulfillmentStatus',
            getOrdersWithPostedInvoices(new Set<Id>{salesOrder.Id}).contains(salesOrder.Id)
                ? 'Consumed'
                : 'Not Fulfilled');
        summary.put('lines', lines);
        summary.put('dispatches', getDispatchDetails(salesOrder.Id, distributor.Id));
        summary.put('goodsReceipts', getGoodsReceiptDetails(salesOrder.Id, distributor.Id));
        Map<String, Object> invoice = getInvoiceDetails(salesOrder.Id, distributor.Id);
        summary.put('invoice', invoice);
        if (invoice != null) {
            summary.put('invoiceId', invoice.get('id'));
            summary.put('invoiceNumber', invoice.get('number'));
            summary.put('invoiceStatus', invoice.get('status'));
            summary.put('invoiceTotal', invoice.get('total'));
        }
        summary.put('taxAmount', hasTaxSnapshots ? taxTotal.setScale(2) : null);
        summary.put('totalWithTax', hasTaxSnapshots
            ? ((salesOrder.TotalAmount == null ? 0 : salesOrder.TotalAmount) + taxTotal).setScale(2)
            : null);
        return summary;
    }

    private static Map<Id, Map<String, Object>> getLatestDispatchSummaries(
        Set<Id> orderIds,
        Id distributorId
    ) {
        Map<Id, Map<String, Object>> summaries = new Map<Id, Map<String, Object>>();
        if (orderIds == null || orderIds.isEmpty()) return summaries;

        Set<Id> dispatchIds = new Set<Id>();
        for (DMS_Dispatch__c dispatch : [
            SELECT Id, Name, Order__c, Status__c, Delivery_Status__c,
                   LastModifiedDate
            FROM DMS_Dispatch__c
            WHERE Order__c IN :orderIds
              AND Distributor__c = :distributorId
            ORDER BY CreatedDate DESC, Id DESC
        ]) {
            if (!summaries.containsKey(dispatch.Order__c)) {
                summaries.put(dispatch.Order__c, new Map<String, Object>{
                    'dispatchId' => dispatch.Id,
                    'dispatchNumber' => dispatch.Name,
                    'dispatchStatus' => dispatch.Status__c,
                    'dispatchDeliveryStatus' => dispatch.Delivery_Status__c,
                    'dispatchUpdatedAt' => dispatch.LastModifiedDate
                });
                dispatchIds.add(dispatch.Id);
            }
        }
        Map<Id, String> approvalStatuses = new Map<Id, String>();
        for (ProcessInstance instance : [
            SELECT TargetObjectId, Status
            FROM ProcessInstance
            WHERE TargetObjectId IN :dispatchIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!approvalStatuses.containsKey(instance.TargetObjectId)) {
                approvalStatuses.put(instance.TargetObjectId, instance.Status);
            }
        }
        for (Map<String, Object> summary : summaries.values()) {
            String approvalStatus = approvalStatuses.get((Id) summary.get('dispatchId'));
            String status = (String) summary.get('dispatchStatus');
            if (status == 'Draft' && approvalStatus == 'Pending') status = 'Submitted';
            if (status == 'Draft' && approvalStatus == 'Approved') status = 'Approved';
            if (status == 'Draft' && approvalStatus == 'Rejected') status = 'Rejected';
            summary.put('dispatchStatus', status);
            summary.put('dispatchApprovalStatus', approvalStatus == null
                ? 'Not Submitted'
                : approvalStatusLabel(approvalStatus));
        }
        return summaries;
    }

    private static Map<Id, Map<String, Object>> getLatestGoodsReceiptSummaries(
        Set<Id> orderIds,
        Id distributorId
    ) {
        Map<Id, Map<String, Object>> summaries = new Map<Id, Map<String, Object>>();
        if (orderIds == null || orderIds.isEmpty()) return summaries;

        for (Goods_Receipt_Note__c receipt : [
            SELECT Id, Name, Order__c, GRN_Date__c, GRN_Status__c,
                   Accepted_Quantity__c, Received_Quantity__c, Damaged_Quantity__c,
                   LastModifiedDate
            FROM Goods_Receipt_Note__c
            WHERE Order__c IN :orderIds
              AND Distributor__c = :distributorId
            ORDER BY GRN_Date__c DESC, CreatedDate DESC, Id DESC
        ]) {
            if (!summaries.containsKey(receipt.Order__c)) {
                summaries.put(receipt.Order__c, new Map<String, Object>{
                    'grnId' => receipt.Id,
                    'grnNumber' => receipt.Name,
                    'grnDate' => receipt.GRN_Date__c,
                    'grnStatus' => receipt.GRN_Status__c,
                    'grnAcceptedQuantity' => receipt.Accepted_Quantity__c,
                    'grnReceivedQuantity' => receipt.Received_Quantity__c,
                    'grnDamagedQuantity' => receipt.Damaged_Quantity__c,
                    'grnUpdatedAt' => receipt.LastModifiedDate
                });
            }
        }
        return summaries;
    }

    private static List<Map<String, Object>> getDispatchDetails(
        Id orderId,
        Id distributorId
    ) {
        List<Map<String, Object>> dispatches = new List<Map<String, Object>>();
        Map<Id, Map<String, Object>> dispatchById = new Map<Id, Map<String, Object>>();
        Set<Id> dispatchIds = new Set<Id>();
        List<DMS_Dispatch__c> dispatchRecords = [
            SELECT Id, Name, Order__c, Order__r.Type, Invoice__c, Invoice__r.Name,
                   Warehouse__c, Warehouse__r.Name, Status__c, Delivery_Status__c,
                   Dispatch_Date__c, Expected_Delivery_Date__c,
                   Actual_Dispatch_Date__c, Actual_Delivery_Date__c,
                   Tracking_Number__c, Transporter_Name__c, Vehicle_Number__c,
                   Recipient_Name__c, Delivery_Remarks__c, LastModifiedDate
            FROM DMS_Dispatch__c
            WHERE Order__c = :orderId
              AND Distributor__c = :distributorId
            ORDER BY CreatedDate DESC, Id DESC
        ];
        for (DMS_Dispatch__c dispatch : dispatchRecords) dispatchIds.add(dispatch.Id);
        Map<Id, String> approvalStatuses = new Map<Id, String>();
        for (ProcessInstance instance : [
            SELECT TargetObjectId, Status
            FROM ProcessInstance
            WHERE TargetObjectId IN :dispatchIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!approvalStatuses.containsKey(instance.TargetObjectId)) {
                approvalStatuses.put(instance.TargetObjectId, instance.Status);
            }
        }
        for (DMS_Dispatch__c dispatch : dispatchRecords) {
            String approvalStatus = approvalStatuses.get(dispatch.Id);
            String dispatchStatus = dispatch.Status__c;
            if (dispatchStatus == 'Draft' && approvalStatus == 'Pending') {
                dispatchStatus = 'Submitted';
            } else if (dispatchStatus == 'Draft' && approvalStatus == 'Approved') {
                dispatchStatus = 'Approved';
            } else if (dispatchStatus == 'Draft' && approvalStatus == 'Rejected') {
                dispatchStatus = 'Rejected';
            }
            Map<String, Object> detail = new Map<String, Object>{
                'id' => dispatch.Id,
                'number' => dispatch.Name,
                'orderId' => dispatch.Order__c,
                'orderType' => dispatch.Order__r == null ? null : dispatch.Order__r.Type,
                'invoiceId' => dispatch.Invoice__c,
                'invoiceNumber' => dispatch.Invoice__r == null
                    ? null
                    : dispatch.Invoice__r.Name,
                'warehouseId' => dispatch.Warehouse__c,
                'warehouseName' => dispatch.Warehouse__r == null
                    ? null
                    : dispatch.Warehouse__r.Name,
                'status' => dispatchStatus,
                'approvalStatus' => approvalStatus == null
                    ? 'Not Submitted'
                    : approvalStatusLabel(approvalStatus),
                'deliveryStatus' => dispatch.Delivery_Status__c,
                'dispatchDate' => dispatch.Dispatch_Date__c,
                'expectedDeliveryDate' => dispatch.Expected_Delivery_Date__c,
                'actualDispatchDate' => dispatch.Actual_Dispatch_Date__c,
                'actualDeliveryDate' => dispatch.Actual_Delivery_Date__c,
                'trackingNumber' => dispatch.Tracking_Number__c,
                'transporterName' => dispatch.Transporter_Name__c,
                'vehicleNumber' => dispatch.Vehicle_Number__c,
                'recipientName' => dispatch.Recipient_Name__c,
                'deliveryRemarks' => dispatch.Delivery_Remarks__c,
                'lastUpdatedAt' => dispatch.LastModifiedDate,
                'lines' => new List<Map<String, Object>>()
            };
            dispatches.add(detail);
            dispatchById.put(dispatch.Id, detail);
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
                'lineType' => getOrderLineType(
                    line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Paid_Quantity__c,
                    line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Free_Quantity__c
                ),
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
        return dispatches;
    }

    private static String getOrderLineType(Decimal paidQuantity, Decimal freeQuantity) {
        Boolean hasPaid = paidQuantity != null && paidQuantity > 0;
        Boolean hasFree = freeQuantity != null && freeQuantity > 0;
        if (hasPaid && hasFree) return 'Paid + Free';
        if (hasFree) return 'Free';
        if (hasPaid) return 'Paid';
        return 'Not recorded';
    }

    private static List<Map<String, Object>> getGoodsReceiptDetails(
        Id orderId,
        Id distributorId
    ) {
        List<Map<String, Object>> receipts = new List<Map<String, Object>>();
        Map<Id, Map<String, Object>> receiptById = new Map<Id, Map<String, Object>>();
        Set<Id> receiptIds = new Set<Id>();
        for (Goods_Receipt_Note__c receipt : [
            SELECT Id, Name, Order__c, Warehouse__c, Warehouse__r.Name,
                   GRN_Date__c, GRN_Status__c, Expected_Quantity__c,
                   Received_Quantity__c, Accepted_Quantity__c, Damaged_Quantity__c,
                   Supplier_Delivery_Number__c, Received_By__c, Remarks__c,
                   LastModifiedDate, DMS_Dispatch__c, DMS_Dispatch__r.Name,
                   Distributor__r.Name
            FROM Goods_Receipt_Note__c
            WHERE Order__c = :orderId
              AND Distributor__c = :distributorId
            ORDER BY GRN_Date__c DESC, CreatedDate DESC, Id DESC
        ]) {
            Map<String, Object> detail = new Map<String, Object>{
                'id' => receipt.Id,
                'number' => receipt.Name,
                'orderId' => receipt.Order__c,
                'dispatchId' => receipt.DMS_Dispatch__c,
                'dispatchNumber' => receipt.DMS_Dispatch__r == null
                    ? null
                    : receipt.DMS_Dispatch__r.Name,
                'distributorName' => receipt.Distributor__r == null
                    ? null
                    : receipt.Distributor__r.Name,
                'warehouseName' => receipt.Warehouse__r == null
                    ? null
                    : receipt.Warehouse__r.Name,
                'date' => receipt.GRN_Date__c,
                'status' => receipt.GRN_Status__c,
                'expectedQuantity' => receipt.Expected_Quantity__c,
                'receivedQuantity' => receipt.Received_Quantity__c,
                'acceptedQuantity' => receipt.Accepted_Quantity__c,
                'damagedQuantity' => receipt.Damaged_Quantity__c,
                'supplierDeliveryNumber' => receipt.Supplier_Delivery_Number__c,
                'receivedBy' => receipt.Received_By__c,
                'remarks' => receipt.Remarks__c,
                'lastUpdatedAt' => receipt.LastModifiedDate,
                'lines' => new List<Map<String, Object>>()
            };
            receipts.add(detail);
            receiptById.put(receipt.Id, detail);
            receiptIds.add(receipt.Id);
        }
        for (Goods_Receipt_Line_Item__c line : [
            SELECT Id, Goods_Receipt_Note__c, DMS_Dispatch_Line__c,
                   DMS_Dispatch_Line__r.Quantity__c,
                   DMS_Dispatch_Line__r.Quantity_Short__c,
                   DMS_Dispatch_Line__r.Unit_of_Measure__c,
                   DMS_Dispatch_Line__r.Product_Name_Snapshot__c,
                   Order_Line_Item__r.Paid_Quantity__c,
                   Order_Line_Item__r.Free_Quantity__c,
                   Order_Line_Item__r.Unit_of_Measure__c,
                   Order_Line_Item__c,
                   Product__c, Product__r.Name, Expected_Quantity__c,
                   Received_Quantity__c, Accepted_Quantity__c,
                   Damaged_Quantity__c, Remarks__c
            FROM Goods_Receipt_Line_Item__c
            WHERE Goods_Receipt_Note__c IN :receiptIds
            ORDER BY CreatedDate, Id
        ]) {
            List<Map<String, Object>> lines =
                (List<Map<String, Object>>) receiptById.get(line.Goods_Receipt_Note__c).get('lines');
            lines.add(new Map<String, Object>{
                'id' => line.Id,
                'dispatchLineId' => line.DMS_Dispatch_Line__c,
                'orderItemId' => line.Order_Line_Item__c,
                'productId' => line.Product__c,
                'productName' => line.Product__r == null
                    ? (line.DMS_Dispatch_Line__r == null
                        ? null
                        : line.DMS_Dispatch_Line__r.Product_Name_Snapshot__c)
                    : line.Product__r.Name,
                'lineType' => getOrderLineType(
                    line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Paid_Quantity__c,
                    line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Free_Quantity__c
                ),
                'expectedQuantity' => line.Expected_Quantity__c,
                'dispatchedQuantity' => line.DMS_Dispatch_Line__r == null
                    ? null
                    : line.DMS_Dispatch_Line__r.Quantity__c,
                'receivedQuantity' => line.Received_Quantity__c,
                'acceptedQuantity' => line.Accepted_Quantity__c,
                'damagedQuantity' => line.Damaged_Quantity__c,
                'shortQuantity' => line.DMS_Dispatch_Line__r == null
                    ? null
                    : line.DMS_Dispatch_Line__r.Quantity_Short__c,
                'unitOfMeasure' => line.DMS_Dispatch_Line__r == null
                    ? (line.Order_Line_Item__r == null
                        ? null
                        : line.Order_Line_Item__r.Unit_of_Measure__c)
                    : line.DMS_Dispatch_Line__r.Unit_of_Measure__c,
                'remarks' => line.Remarks__c
            });
        }
        return receipts;
    }

    private static Map<Id, Map<String, Object>> getInvoiceSummaries(
        Set<Id> orderIds,
        Id distributorId
    ) {
        Map<Id, Map<String, Object>> summaries =
            new Map<Id, Map<String, Object>>();
        if (orderIds == null || orderIds.isEmpty()) return summaries;

        Map<Id, DMS_Invoice__c> invoiceById = new Map<Id, DMS_Invoice__c>();
        Map<Id, Id> orderByInvoiceId = new Map<Id, Id>();
        Set<Id> invoiceIds = new Set<Id>();
        for (DMS_Invoice__c invoice : [
            SELECT Id, Name, Invoice_Date__c, Status__c, Secondary_Order__c,
                   Secondary_Order__r.OrderNumber, Secondary_Order__r.Type,
                   Retailer__c, Retailer__r.Name, Warehouse__c, Warehouse__r.Name,
                   Subtotal__c, Total_Discount__c, Taxable_Amount__c,
                   Tax_Amount__c, Invoice_Total__c, Amount_Paid__c, Balance_Due__c
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c IN :orderIds
              AND Distributor__c = :distributorId
            ORDER BY CreatedDate DESC, Id DESC
        ]) {
            if (summaries.containsKey(invoice.Secondary_Order__c)) continue;
            invoiceById.put(invoice.Id, invoice);
            orderByInvoiceId.put(invoice.Id, invoice.Secondary_Order__c);
            invoiceIds.add(invoice.Id);
            summaries.put(invoice.Secondary_Order__c, new Map<String, Object>());
        }

        Map<Id, List<Map<String, Object>>> linesByInvoice =
            new Map<Id, List<Map<String, Object>>>();
        for (DMS_Invoice_Line__c line : [
            SELECT Id, Invoice__c, Product__r.Name, Quantity__c,
                   Unit_Price__c, Gross_Amount__c, Discount_Amount__c,
                   Taxable_Amount__c, Tax_Rate__c, Tax_Amount__c,
                   Line_Total__c, Unit_of_Measure__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c IN :invoiceIds
            ORDER BY CreatedDate, Id
        ]) {
            if (!linesByInvoice.containsKey(line.Invoice__c)) {
                linesByInvoice.put(line.Invoice__c, new List<Map<String, Object>>());
            }
            linesByInvoice.get(line.Invoice__c).add(new Map<String, Object>{
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

        for (Id invoiceId : invoiceById.keySet()) {
            DMS_Invoice__c invoice = invoiceById.get(invoiceId);
            String salesType = invoice.Secondary_Order__r == null
                ? null
                : (invoice.Secondary_Order__r.Type == 'Primary Order'
                    ? 'Primary'
                    : 'Secondary');
            Map<String, Object> detail = new Map<String, Object>{
                'id' => invoice.Id,
                'number' => invoice.Name,
                'date' => invoice.Invoice_Date__c,
                'status' => invoice.Status__c,
                'orderId' => invoice.Secondary_Order__c,
                'orderNumber' => invoice.Secondary_Order__r == null
                    ? null
                    : invoice.Secondary_Order__r.OrderNumber,
                'salesType' => salesType,
                'customerName' => invoice.Retailer__r == null
                    ? null
                    : invoice.Retailer__r.Name,
                'warehouseId' => invoice.Warehouse__c,
                'warehouseName' => invoice.Warehouse__r == null
                    ? null
                    : invoice.Warehouse__r.Name,
                'subtotal' => invoice.Subtotal__c,
                'discount' => invoice.Total_Discount__c,
                'taxableAmount' => invoice.Taxable_Amount__c,
                'tax' => invoice.Tax_Amount__c,
                'total' => invoice.Invoice_Total__c,
                'amountPaid' => invoice.Amount_Paid__c,
                'balanceDue' => invoice.Balance_Due__c,
                'lines' => linesByInvoice.containsKey(invoiceId)
                    ? linesByInvoice.get(invoiceId)
                    : new List<Map<String, Object>>()
            };
            summaries.get(orderByInvoiceId.get(invoiceId)).putAll(new Map<String, Object>{
                'invoice' => detail,
                'invoiceId' => invoice.Id,
                'invoiceNumber' => invoice.Name,
                'invoiceStatus' => invoice.Status__c,
                'invoiceTotal' => invoice.Invoice_Total__c
            });
        }
        return summaries;
    }

    private static Map<String, Object> getInvoiceDetails(Id orderId, Id distributorId) {
        Map<Id, Map<String, Object>> summaries =
            getInvoiceSummaries(new Set<Id>{orderId}, distributorId);
        if (!summaries.containsKey(orderId)) return null;
        return (Map<String, Object>) summaries.get(orderId).get('invoice');
    }

    private static void submitOrderForApproval(
        Account distributor,
        Map<String, Object> payload,
        String salesType,
        RestResponse response
    ) {
        Id orderId = parseId(stringValue(payload.get('orderId')));
        if (orderId == null || orderId.getSObjectType() != Order.SObjectType) {
            throw new RequestException('A valid order ID is required.');
        }

        List<Order> matchingOrders = [
            SELECT Id, OrderNumber, Type, Status, AccountId, Outlet__c, OwnerId,
                   DMS_Approver__c
            FROM Order
            WHERE Id = :orderId AND AccountId = :distributor.Id
              AND Type = :orderType(salesType)
            LIMIT 1
            FOR UPDATE
        ];
        if (matchingOrders.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => 'The requested order is not available to this distributor.'
            });
            return;
        }
        Order salesOrder = matchingOrders[0];
        if (salesType == 'Secondary') {
            throw new ConflictException(
                'Secondary orders do not require approval. Create an invoice directly.'
            );
        }

        Map<String, Object> currentApproval =
            getApprovalSummaries(new Set<Id>{salesOrder.Id}).get(salesOrder.Id);
        String approvalStatus = (String) currentApproval.get('approvalStatus');
        if (approvalStatus == 'Pending Approval') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'order' => getOrderDetails(distributor, salesOrder.Id),
                'message' => 'This order is already pending approval.'
            });
            return;
        }
        if (approvalStatus == 'Approved') {
            throw new ConflictException('An approved order cannot be submitted again.');
        }
        if (salesOrder.Status != 'Draft') {
            throw new ConflictException('Only draft orders can be submitted for approval.');
        }

        if (salesType == 'Secondary') {
            if (salesOrder.Outlet__c == null || [
                SELECT Id
                FROM Account
                WHERE Id = :salesOrder.Outlet__c
                  AND Distributor__c = :distributor.Id
                  AND Account_Category__c = 'Outlet'
                  AND Active__c = 'Yes'
                LIMIT 1
            ].isEmpty()) {
                throw new ConflictException(
                    'The order retailer is inactive or is no longer assigned to your distributor.'
                );
            }
        }

        List<OrderItem> orderLines = [
            SELECT Id, Quantity, UnitPrice, ListPrice, DMS_List_Price__c,
                   Unit_of_Measure__c, DMS_Tax_Rate__c, DMS_Tax_Amount__c, Product2Id,
                   Product2.IsActive, Product2.DMS_Tax_Rate__c
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ];
        if (orderLines.isEmpty()) {
            throw new ConflictException('An order must contain valid product lines before approval.');
        }
        for (OrderItem line : orderLines) {
            Decimal listPrice = line.DMS_List_Price__c == null
                ? line.ListPrice
                : line.DMS_List_Price__c;
            if (line.Product2Id == null || !line.Product2.IsActive
                || line.Quantity == null || line.Quantity <= 0
                || line.UnitPrice == null || line.UnitPrice < 0
                || listPrice == null || listPrice < line.UnitPrice
                || String.isBlank(line.Unit_of_Measure__c)
                || (line.DMS_Tax_Rate__c != null
                    && (line.DMS_Tax_Rate__c < 0 || line.DMS_Tax_Rate__c > 100))) {
                throw new ConflictException(
                    'The order contains a product, quantity, price, unit, or tax configuration that is no longer valid.'
                );
            }
        }

        Decimal expectedSubtotal = 0;
        Decimal expectedDiscount = 0;
        Decimal expectedTaxable = 0;
        Decimal expectedTax = 0;
        for (OrderItem line : orderLines) {
            Decimal listPrice = line.DMS_List_Price__c == null
                ? line.ListPrice
                : line.DMS_List_Price__c;
            expectedSubtotal += (listPrice * line.Quantity).setScale(2);
            expectedDiscount += ((listPrice - line.UnitPrice) * line.Quantity).setScale(2);
            expectedTaxable += (line.UnitPrice * line.Quantity).setScale(2);
            if (line.DMS_Tax_Amount__c != null) {
                expectedTax += line.DMS_Tax_Amount__c;
            } else {
                Decimal taxRate = line.DMS_Tax_Rate__c == null
                    ? (line.Product2.DMS_Tax_Rate__c == null
                        ? 0
                        : line.Product2.DMS_Tax_Rate__c)
                    : line.DMS_Tax_Rate__c;
                expectedTax += (
                    (line.UnitPrice * line.Quantity).setScale(2)
                    * taxRate / 100
                ).setScale(2);
            }
        }
        expectedSubtotal = expectedSubtotal.setScale(2);
        expectedDiscount = expectedDiscount.setScale(2);
        expectedTaxable = expectedTaxable.setScale(2);
        expectedTax = expectedTax.setScale(2);

        if (salesType == 'Secondary') {
            List<DMS_Invoice__c> orderInvoices = [
                SELECT Id, Name, Status__c, Subtotal__c, Total_Discount__c,
                       Taxable_Amount__c, Tax_Amount__c, Invoice_Total__c
                FROM DMS_Invoice__c
                WHERE Secondary_Order__c = :salesOrder.Id
                  AND Distributor__c = :distributor.Id
                LIMIT 1
                FOR UPDATE
            ];
            if (orderInvoices.isEmpty() || orderInvoices[0].Status__c != 'Draft') {
                throw new ConflictException(
                    'Generate and review a Draft invoice for this order before submitting it for approval.'
                );
            }
            DMS_Invoice__c draftInvoice = orderInvoices[0];
            AggregateResult invoiceLineTotals = [
                SELECT COUNT(Id) lineCount, SUM(Line_Total__c) lineTotal
                FROM DMS_Invoice_Line__c
                WHERE Invoice__c = :draftInvoice.Id
            ];
            Decimal savedLineTotal = (Decimal) invoiceLineTotals.get('lineTotal');
            Decimal expectedInvoiceTotal = (expectedTaxable + expectedTax).setScale(2);
            if ((Integer) invoiceLineTotals.get('lineCount') != orderLines.size()
                || draftInvoice.Subtotal__c != expectedSubtotal
                || draftInvoice.Total_Discount__c != expectedDiscount
                || draftInvoice.Taxable_Amount__c != expectedTaxable
                || draftInvoice.Tax_Amount__c != expectedTax
                || draftInvoice.Invoice_Total__c != expectedInvoiceTotal
                || savedLineTotal == null
                || savedLineTotal.setScale(2) != expectedInvoiceTotal) {
                throw new ConflictException(
                    'The saved Draft invoice no longer matches the order lines and tax calculation.'
                );
            }
        }

        DMS_Order_Approval_Config__mdt approvalConfig =
            DMS_Order_Approval_Config__mdt.getInstance('Default');
        if (approvalConfig == null || String.isBlank(approvalConfig.Approver_Username__c)) {
            throw new ConflictException(
                'The designated Salesforce approver is not configured. '
                + 'Set Approver Username on DMS Order Approval Config (Default).'
            );
        }
        List<User> approvers = [
            SELECT Id, Name
            FROM User
            WHERE Username = :approvalConfig.Approver_Username__c
              AND IsActive = true
            LIMIT 2
        ];
        if (approvers.size() != 1) {
            throw new ConflictException(
                'The configured username must identify exactly one active Salesforce user.'
            );
        }
        if (approvers[0].Id == salesOrder.OwnerId) {
            throw new ConflictException(
                'The configured approver cannot approve an order submitted by the same Salesforce user.'
            );
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            salesOrder.DMS_Approver__c = approvers[0].Id;
            update salesOrder;

            Approval.ProcessSubmitRequest approvalRequest =
                new Approval.ProcessSubmitRequest();
            approvalRequest.setObjectId(salesOrder.Id);
            approvalRequest.setSubmitterId(String.valueOf(salesOrder.OwnerId));
            approvalRequest.setComments(
                'Order submitted for approval from the DMS distributor portal.'
            );
            Approval.ProcessResult result = Approval.process(approvalRequest);
            if (!result.isSuccess()) {
                Database.rollback(savepoint);
                List<String> messages = new List<String>();
                for (Database.Error approvalError : result.getErrors()) {
                    messages.add(approvalError.getMessage());
                }
                throw new ConflictException(messages.isEmpty()
                    ? 'No matching active Salesforce Order approval process is configured.'
                    : 'Salesforce approval submission failed: ' + String.join(messages, ' '));
            }

            Map<String, Object> submittedApproval =
                getApprovalSummaries(new Set<Id>{salesOrder.Id}).get(salesOrder.Id);
            if (submittedApproval.get('approvalStatus') != 'Pending Approval') {
                Database.rollback(savepoint);
                throw new ConflictException(
                    'Salesforce did not confirm a pending approval request for this order.'
                );
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'order' => getOrderDetails(distributor, salesOrder.Id)
            });
        } catch (ConflictException error) {
            throw error;
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR,
                'DMS Order approval submission failed: ' + error.getMessage() +
                '\n' + error.getStackTraceString());
            throw new ConflictException(
                'Salesforce could not submit this order for approval. Verify the active approval process and try again.'
            );
        }
    }

    private static void performStockAction(
        Account distributor,
        Map<String, Object> payload,
        String action,
        RestResponse response
    ) {
        Id orderId = parseId(stringValue(payload.get('orderId')));
        if (orderId.getSObjectType() != Order.SObjectType) {
            throw new RequestException('A valid order ID is required.');
        }
        List<Order> orders = [
            SELECT Id, OrderNumber, Type, Status, AccountId, Outlet__c,
                   DMS_Fulfillment_Warehouse__c, DMS_Allocation_Status__c
            FROM Order
            WHERE Id = :orderId AND AccountId = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty()) {
            throw new ConflictException('The requested order is not available to this distributor.');
        }
        Order salesOrder = orders[0];

        if (action == 'reservationStatus') {
            requireReservationReadPermissions();
            writeResponse(response, 200, reservationStatus(distributor, salesOrder));
            return;
        }
        if (action == 'releaseStockReservation') {
            requireReservationWritePermissions();
            releaseStockReservation(distributor, salesOrder, response);
            return;
        }

        if (salesOrder.Status != 'Activated') {
            throw new ConflictException('Only activated orders can be allocated, validated, or reserved.');
        }
        if (salesOrder.Type != 'Secondary Order') {
            throw new ConflictException(
                'Stock validation and reservation are for Secondary Orders. Receive Primary Order deliveries through a goods receipt.'
            );
        }
        if (salesOrder.Outlet__c == null || [
            SELECT Id
            FROM Account
            WHERE Id = :salesOrder.Outlet__c
              AND Distributor__c = :distributor.Id
              AND Account_Category__c = 'Outlet'
              AND Active__c = 'Yes'
            LIMIT 1
        ].isEmpty()) {
            throw new ConflictException('The order retailer is inactive or is no longer assigned to your distributor.');
        }
        if (![SELECT Id FROM DMS_Invoice__c
              WHERE Secondary_Order__c = :salesOrder.Id AND Status__c = 'Posted'
              LIMIT 1].isEmpty()) {
            throw new ConflictException('Fulfilled orders cannot be reserved again.');
        }

        if (action == 'findWarehouses') {
            findWarehouses(distributor, salesOrder, response);
            return;
        }

        if (action == 'allocateStock') {
            allocateStock(distributor, salesOrder, payload, response);
            return;
        }

        Id warehouseId = parseOptionalId(payload.get('warehouseId'));
        if (warehouseId == null || warehouseId.getSObjectType() != Warehouse__c.SObjectType) {
            throw new RequestException('Select a valid fulfillment warehouse.');
        }
        StockCheck check = prepareStockCheck(distributor, salesOrder, warehouseId);
        if (action == 'validateStock') {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'orderId' => salesOrder.Id,
                'orderNumber' => salesOrder.OrderNumber,
                'warehouseId' => warehouseId,
                'canReserve' => check.canReserve,
                'status' => check.canReserve ? 'available' : 'insufficient',
                'lines' => check.lines
            });
            return;
        }
        requireMatchingAllocation(salesOrder, warehouseId, check);
        requireReservationWritePermissions();
        reserveStock(distributor, salesOrder, warehouseId, check, payload, response);
    }

    global static void releaseIneligibleOrderReservations(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;

        List<Order> ineligibleOrders = [
            SELECT Id, OrderNumber, AccountId, Status, DMS_Allocation_Status__c
            FROM Order
            WHERE Id IN :orderIds
              AND Status != 'Activated'
              AND DMS_Allocation_Status__c = 'Reserved'
            FOR UPDATE
        ];
        if (ineligibleOrders.isEmpty()) return;

        Set<Id> affectedOrderIds = new Set<Id>();
        Set<Id> distributorIds = new Set<Id>();
        Map<Id, Order> ordersById = new Map<Id, Order>();
        for (Order salesOrder : ineligibleOrders) {
            affectedOrderIds.add(salesOrder.Id);
            distributorIds.add(salesOrder.AccountId);
            ordersById.put(salesOrder.Id, salesOrder);
        }

        Set<Id> fulfilledOrderIds = new Set<Id>();
        for (DMS_Invoice__c invoice : [
            SELECT Secondary_Order__c
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c IN :affectedOrderIds
              AND Status__c = 'Posted'
        ]) {
            fulfilledOrderIds.add(invoice.Secondary_Order__c);
        }

        Set<Id> releasableOrderIds = new Set<Id>();
        releasableOrderIds.addAll(affectedOrderIds);
        releasableOrderIds.removeAll(fulfilledOrderIds);
        Map<Id, Decimal> releaseByInventory = new Map<Id, Decimal>();
        Map<String, Decimal> activeByReferenceInventory = new Map<String, Decimal>();
        Map<String, Id> inventoryByReferenceInventory = new Map<String, Id>();
        Map<String, Id> orderByReferenceInventory = new Map<String, Id>();
        if (!releasableOrderIds.isEmpty()) {
            List<String> referenceFilters = new List<String>();
            for (Id orderId : releasableOrderIds) {
                referenceFilters.add(
                    'Reference_Number__c LIKE \'DMS-RES-' + String.valueOf(orderId) + '-%\''
                );
            }
            Set<String> transactionTypes = new Set<String>{
                'Stock Reservation', 'Stock Release'
            };
            String ledgerQuery = 'SELECT Inventory__c, Reference_Number__c, '
                + 'Transaction_Type__c, Quantity__c FROM Inventory_Transaction__c '
                + 'WHERE Transaction_Type__c IN :transactionTypes '
                + 'AND Inventory__r.Warehouse__r.Distributor__c IN :distributorIds '
                + 'AND Inventory__r.Warehouse__r.Warehouse_Type__c = \'Distributor Warehouse\' '
                + 'AND (' + String.join(referenceFilters, ' OR ') + ') '
                + 'ORDER BY CreatedDate, Id';
            for (Inventory_Transaction__c stockEntry : Database.query(ledgerQuery)) {
                String key = stockEntry.Reference_Number__c + ':' + stockEntry.Inventory__c;
                Decimal quantity = stockEntry.Quantity__c == null
                    ? 0
                    : stockEntry.Quantity__c;
                Decimal activeQuantity = activeByReferenceInventory.containsKey(key)
                    ? activeByReferenceInventory.get(key)
                    : 0;
                activeQuantity += stockEntry.Transaction_Type__c == 'Stock Reservation'
                    ? quantity
                    : -quantity;
                activeByReferenceInventory.put(key, activeQuantity);
                inventoryByReferenceInventory.put(key, stockEntry.Inventory__c);
                for (Id orderId : releasableOrderIds) {
                    if (stockEntry.Reference_Number__c.startsWith(
                        'DMS-RES-' + String.valueOf(orderId) + '-'
                    )) {
                        orderByReferenceInventory.put(key, orderId);
                        break;
                    }
                }
            }
        }

        for (String key : activeByReferenceInventory.keySet()) {
            Decimal quantity = activeByReferenceInventory.get(key);
            if (quantity < 0) {
                throw new ConflictException(
                    'The reservation ledger is inconsistent. The order could not be cancelled.'
                );
            }
            if (quantity > 0) {
                Id inventoryId = inventoryByReferenceInventory.get(key);
                releaseByInventory.put(
                    inventoryId,
                    (releaseByInventory.containsKey(inventoryId)
                        ? releaseByInventory.get(inventoryId)
                        : 0) + quantity
                );
            }
        }

        List<Inventory__c> inventoryRecords = new List<Inventory__c>();
        if (!releaseByInventory.isEmpty()) {
            inventoryRecords = [
                SELECT Id, Available_Quantity__c, Reserved_Quantity__c
                FROM Inventory__c
                WHERE Id IN :releaseByInventory.keySet()
                FOR UPDATE
            ];
            if (inventoryRecords.size() != releaseByInventory.size()) {
                throw new ConflictException(
                    'A reserved inventory balance is missing. The order could not be cancelled.'
                );
            }
            ensureTransactionType('Stock Release');
            for (Inventory__c inventory : inventoryRecords) {
                Decimal quantity = releaseByInventory.get(inventory.Id);
                Decimal reserved = inventory.Reserved_Quantity__c == null
                    ? 0
                    : inventory.Reserved_Quantity__c;
                if (reserved < quantity) {
                    throw new ConflictException(
                        'The inventory balance no longer matches its reservation ledger.'
                    );
                }
                inventory.Reserved_Quantity__c = reserved - quantity;
                inventory.Available_Quantity__c =
                    (inventory.Available_Quantity__c == null
                        ? 0
                        : inventory.Available_Quantity__c) + quantity;
            }
            update inventoryRecords;

            List<Inventory_Transaction__c> releaseTransactions =
                new List<Inventory_Transaction__c>();
            for (String key : activeByReferenceInventory.keySet()) {
                Decimal quantity = activeByReferenceInventory.get(key);
                if (quantity <= 0) continue;
                Integer separatorIndex = key.indexOf(':');
                Id orderId = orderByReferenceInventory.get(key);
                releaseTransactions.add(new Inventory_Transaction__c(
                    Inventory__c = inventoryByReferenceInventory.get(key),
                    Transaction_Type__c = 'Stock Release',
                    Quantity__c = quantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = key.substring(0, separatorIndex),
                    Transaction_Description__c = 'Reservation released for cancelled order '
                        + ordersById.get(orderId).OrderNumber
                ));
            }
            insert releaseTransactions;
        }

        List<DMS_Order_Allocation__c> allocations = [
            SELECT Id, Allocation_Status__c
            FROM DMS_Order_Allocation__c
            WHERE Order__c IN :affectedOrderIds
              AND Allocation_Status__c IN ('Allocated', 'Reserved')
            FOR UPDATE
        ];
        for (DMS_Order_Allocation__c allocation : allocations) {
            allocation.Allocation_Status__c = 'Released';
        }
        if (!allocations.isEmpty()) update allocations;
        for (Order salesOrder : ineligibleOrders) {
            salesOrder.DMS_Allocation_Status__c = 'Not Allocated';
        }
        update ineligibleOrders;
    }

    private static StockCheck prepareStockCheck(
        Account distributor,
        Order salesOrder,
        Id warehouseId
    ) {
        List<Warehouse__c> warehouses = [
            SELECT Id, Name, Warehouse_Type__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouseId
              AND Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
            LIMIT 1
            FOR UPDATE
        ];
        if (warehouses.isEmpty()) {
            throw new ConflictException('The selected warehouse is not available to this distributor.');
        }
        if (warehouses[0].Warehouse_Status__c != 'Active') {
            throw new ConflictException('The selected warehouse is inactive.');
        }

        StockDemand demand = prepareStockDemand(salesOrder);
        List<Inventory__c> inventoryRecords = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c, Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId
              AND Product__c IN :demand.quantitiesByProduct.keySet()
            FOR UPDATE
        ];
        Map<Id, Decimal> allocatedQuantities = getAllocatedQuantities(
            new Set<Id>{warehouseId},
            demand.quantitiesByProduct.keySet(),
            salesOrder.Id
        ).get(warehouseId);
        StockCheck check = buildStockCheck(demand, inventoryRecords, allocatedQuantities);
        return check;
    }

    private static StockDemand prepareStockDemand(Order salesOrder) {
        List<OrderItem> orderLines = [
            SELECT Id, Product2Id, Product2.Name, Product2.IsActive,
                   Product2.SFA_Product__c,
                   Product2.QuantityUnitOfMeasure, Quantity,
                   UnitPrice, Unit_of_Measure__c, Unit_Conversion_Factor__c,
                   PricebookEntryId, PricebookEntry.IsActive
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ];
        if (orderLines.isEmpty() || orderLines.size() > MAX_ORDER_LINES) {
            throw new ConflictException('The order has no valid lines or exceeds the supported line limit.');
        }

        StockDemand demand = new StockDemand();
        demand.quantitiesByProduct = new Map<Id, Decimal>();
        demand.productNames = new Map<Id, String>();
        demand.unitsByProduct = new Map<Id, String>();
        for (OrderItem line : orderLines) {
            if (line.Product2Id == null || line.Product2 == null || !line.Product2.IsActive
                || !line.Product2.SFA_Product__c
                || line.Quantity == null || line.Quantity <= 0
                || line.UnitPrice == null || line.UnitPrice < 0
                || line.PricebookEntryId == null || line.PricebookEntry == null
                || !line.PricebookEntry.IsActive
                || String.isBlank(line.Unit_of_Measure__c)
                || line.Unit_Conversion_Factor__c == null
                || line.Unit_Conversion_Factor__c <= 0) {
                throw new ConflictException('The order contains an invalid or inactive product, quantity, unit, or price reference.');
            }
            Decimal baseQuantity = line.Quantity * line.Unit_Conversion_Factor__c;
            Decimal currentQuantity = demand.quantitiesByProduct.containsKey(line.Product2Id)
                ? demand.quantitiesByProduct.get(line.Product2Id)
                : 0;
            demand.quantitiesByProduct.put(line.Product2Id, currentQuantity + baseQuantity);
            demand.productNames.put(line.Product2Id, line.Product2.Name);
            demand.unitsByProduct.put(line.Product2Id, line.Product2.QuantityUnitOfMeasure);
        }
        return demand;
    }

    private static StockCheck buildStockCheck(
        StockDemand demand,
        List<Inventory__c> inventoryRecords,
        Map<Id, Decimal> allocatedQuantities
    ) {
        StockCheck check = new StockCheck();
        check.quantitiesByProduct = demand.quantitiesByProduct;
        check.inventoryByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c inventory : inventoryRecords) {
            if (check.inventoryByProduct.containsKey(inventory.Product__c)) {
                throw new ConflictException('Duplicate inventory balances exist for a product and warehouse.');
            }
            check.inventoryByProduct.put(inventory.Product__c, inventory);
        }

        check.lines = new List<Map<String, Object>>();
        check.canReserve = true;
        for (Id productId : demand.quantitiesByProduct.keySet()) {
            Inventory__c inventory = check.inventoryByProduct.get(productId);
            Decimal available = inventory == null || inventory.Available_Quantity__c == null
                ? 0
                : inventory.Available_Quantity__c;
            Decimal allocated = allocatedQuantities == null
                || !allocatedQuantities.containsKey(productId)
                ? 0
                : allocatedQuantities.get(productId);
            available = available > allocated ? available - allocated : 0;
            Decimal reserved = inventory == null || inventory.Reserved_Quantity__c == null
                ? 0
                : inventory.Reserved_Quantity__c;
            Decimal required = demand.quantitiesByProduct.get(productId);
            Decimal shortage = required > available ? required - available : 0;
            if (shortage > 0) check.canReserve = false;
            check.lines.add(new Map<String, Object>{
                'productId' => productId,
                'productName' => demand.productNames.get(productId),
                'baseUnitOfMeasure' => demand.unitsByProduct.get(productId),
                'requiredQuantity' => required,
                'availableQuantity' => available,
                'allocatedQuantity' => allocated,
                'reservedQuantity' => reserved,
                'shortageQuantity' => shortage,
                'inventoryId' => inventory == null ? null : inventory.Id,
                'status' => shortage > 0 ? 'insufficient' : 'available'
            });
        }
        return check;
    }

    private static void findWarehouses(
        Account distributor,
        Order salesOrder,
        RestResponse response
    ) {
        StockDemand demand = prepareStockDemand(salesOrder);
        List<Warehouse__c> warehouses = [
            SELECT Id, Name, Warehouse_Type__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
              AND Warehouse_Status__c = 'Active'
            ORDER BY Name, Id
        ];
        List<Map<String, Object>> candidates = new List<Map<String, Object>>();
        List<Map<String, Object>> sufficientCandidates = new List<Map<String, Object>>();
        List<Map<String, Object>> insufficientCandidates = new List<Map<String, Object>>();
        Id recommendedWarehouseId;
        if (!warehouses.isEmpty()) {
            Set<Id> warehouseIds = new Set<Id>();
            for (Warehouse__c warehouse : warehouses) {
                warehouseIds.add(warehouse.Id);
            }
            List<Inventory__c> inventoryRecords = [
                SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                       Reserved_Quantity__c, Minimum_Stock_Level__c
                FROM Inventory__c
                WHERE Warehouse__c IN :warehouseIds
                  AND Product__c IN :demand.quantitiesByProduct.keySet()
            ];
            Map<Id, List<Inventory__c>> inventoryByWarehouse =
                new Map<Id, List<Inventory__c>>();
            for (Inventory__c inventory : inventoryRecords) {
                if (!inventoryByWarehouse.containsKey(inventory.Warehouse__c)) {
                    inventoryByWarehouse.put(inventory.Warehouse__c, new List<Inventory__c>());
                }
                inventoryByWarehouse.get(inventory.Warehouse__c).add(inventory);
            }
            Map<Id, Map<Id, Decimal>> allocationsByWarehouse = getAllocatedQuantities(
                warehouseIds,
                demand.quantitiesByProduct.keySet(),
                salesOrder.Id
            );
            for (Warehouse__c warehouse : warehouses) {
                StockCheck check = buildStockCheck(
                    demand,
                    inventoryByWarehouse.containsKey(warehouse.Id)
                        ? inventoryByWarehouse.get(warehouse.Id)
                        : new List<Inventory__c>(),
                    allocationsByWarehouse.get(warehouse.Id)
                );
                List<Map<String, Object>> candidateLines = new List<Map<String, Object>>();
                for (Map<String, Object> line : check.lines) {
                    Map<String, Object> candidateLine = new Map<String, Object>(line);
                    candidateLine.put(
                        'allocationQuantity',
                        check.canReserve ? line.get('requiredQuantity') : 0
                    );
                    candidateLines.add(candidateLine);
                }
                Map<String, Object> candidate = new Map<String, Object>{
                    'warehouseId' => warehouse.Id,
                    'warehouseName' => warehouse.Name,
                    'status' => check.canReserve ? 'available' : 'insufficient',
                    'allocationStatus' => warehouse.Id == salesOrder.DMS_Fulfillment_Warehouse__c
                        && !String.isBlank(salesOrder.DMS_Allocation_Status__c)
                        ? salesOrder.DMS_Allocation_Status__c
                        : 'Not Allocated',
                    'canAllocate' => check.canReserve,
                    'lines' => candidateLines
                };
                if (check.canReserve) {
                    sufficientCandidates.add(candidate);
                    if (recommendedWarehouseId == null) recommendedWarehouseId = warehouse.Id;
                } else {
                    insufficientCandidates.add(candidate);
                }
            }
        }
        candidates.addAll(sufficientCandidates);
        candidates.addAll(insufficientCandidates);
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'orderId' => salesOrder.Id,
            'orderNumber' => salesOrder.OrderNumber,
            'status' => candidates.isEmpty() ? 'noWarehouses' : 'candidatesFound',
            'recommendedWarehouseId' => recommendedWarehouseId,
            'candidates' => candidates
        });
    }

    private static Map<Id, Map<Id, Decimal>> getAllocatedQuantities(
        Set<Id> warehouseIds,
        Set<Id> productIds,
        Id excludedOrderId
    ) {
        Map<Id, Map<Id, Decimal>> quantitiesByWarehouse =
            new Map<Id, Map<Id, Decimal>>();
        if (warehouseIds == null || warehouseIds.isEmpty()
            || productIds == null || productIds.isEmpty()) {
            return quantitiesByWarehouse;
        }
        for (AggregateResult allocation : [
            SELECT Warehouse__c warehouseId, Product__c productId,
                   SUM(Allocated_Quantity__c) allocatedQuantity
            FROM DMS_Order_Allocation__c
            WHERE Warehouse__c IN :warehouseIds
              AND Product__c IN :productIds
              AND Allocation_Status__c = 'Allocated'
              AND Order__c != :excludedOrderId
            GROUP BY Warehouse__c, Product__c
        ]) {
            Id warehouseId = (Id) allocation.get('warehouseId');
            Id productId = (Id) allocation.get('productId');
            if (!quantitiesByWarehouse.containsKey(warehouseId)) {
                quantitiesByWarehouse.put(warehouseId, new Map<Id, Decimal>());
            }
            quantitiesByWarehouse.get(warehouseId).put(
                productId,
                (Decimal) allocation.get('allocatedQuantity')
            );
        }
        return quantitiesByWarehouse;
    }

    private static Map<Id, List<Map<String, Object>>> getAllocationSummaries(
        Set<Id> orderIds
    ) {
        Map<Id, List<Map<String, Object>>> summaries =
            new Map<Id, List<Map<String, Object>>>();
        if (orderIds == null || orderIds.isEmpty()) return summaries;
        for (Id orderId : orderIds) {
            summaries.put(orderId, new List<Map<String, Object>>());
        }
        for (DMS_Order_Allocation__c allocation : [
            SELECT Order__c, Product__c, Product__r.Name, Warehouse__c,
                   Warehouse__r.Name, Allocated_Quantity__c, Allocation_Status__c,
                   CreatedDate, CreatedBy.Name, LastModifiedDate, LastModifiedBy.Name
            FROM DMS_Order_Allocation__c
            WHERE Order__c IN :orderIds
              AND Allocation_Status__c IN ('Allocated', 'Reserved')
            ORDER BY CreatedDate, Id
        ]) {
            if (!summaries.containsKey(allocation.Order__c)) {
                summaries.put(allocation.Order__c, new List<Map<String, Object>>());
            }
            summaries.get(allocation.Order__c).add(new Map<String, Object>{
                'productId' => allocation.Product__c,
                'productName' => allocation.Product__r == null ? null : allocation.Product__r.Name,
                'warehouseId' => allocation.Warehouse__c,
                'warehouseName' => allocation.Warehouse__r == null
                    ? null
                    : allocation.Warehouse__r.Name,
                'quantity' => allocation.Allocated_Quantity__c,
                'status' => allocation.Allocation_Status__c,
                'allocatedAt' => allocation.CreatedDate,
                'allocatedBy' => allocation.CreatedBy == null
                    ? null
                    : allocation.CreatedBy.Name,
                'updatedAt' => allocation.LastModifiedDate,
                'updatedBy' => allocation.LastModifiedBy == null
                    ? null
                    : allocation.LastModifiedBy.Name
            });
        }
        return summaries;
    }

    private static Set<Id> getOrdersWithPostedInvoices(Set<Id> orderIds) {
        Set<Id> fulfilledOrderIds = new Set<Id>();
        if (orderIds == null || orderIds.isEmpty()) return fulfilledOrderIds;
        for (DMS_Invoice__c invoice : [
            SELECT Secondary_Order__c
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c IN :orderIds
              AND Status__c = 'Posted'
        ]) {
            fulfilledOrderIds.add(invoice.Secondary_Order__c);
        }
        return fulfilledOrderIds;
    }

    private static void allocateStock(
        Account distributor,
        Order salesOrder,
        Map<String, Object> payload,
        RestResponse response
    ) {
        Id warehouseId = parseOptionalId(payload.get('warehouseId'));
        if (warehouseId == null || warehouseId.getSObjectType() != Warehouse__c.SObjectType) {
            throw new RequestException('Select a valid fulfillment warehouse.');
        }
        StockCheck check = prepareStockCheck(distributor, salesOrder, warehouseId);
        List<DMS_Order_Allocation__c> existingAllocations = [
            SELECT Id, Product__c, Warehouse__c, Allocated_Quantity__c,
                   Allocation_Key__c, Allocation_Status__c
            FROM DMS_Order_Allocation__c
            WHERE Order__c = :salesOrder.Id
            FOR UPDATE
        ];
        Map<Id, DMS_Order_Allocation__c> allocationByProduct =
            new Map<Id, DMS_Order_Allocation__c>();
        for (DMS_Order_Allocation__c allocation : existingAllocations) {
            if (allocationByProduct.containsKey(allocation.Product__c)) {
                throw new ConflictException('Duplicate order allocations exist for the same product.');
            }
            if (allocation.Allocation_Status__c == 'Reserved') {
                throw new ConflictException('Release the order reservation before changing its warehouse allocation.');
            }
            allocationByProduct.put(allocation.Product__c, allocation);
        }
        Boolean alreadyAllocated =
            salesOrder.DMS_Fulfillment_Warehouse__c == warehouseId
            && salesOrder.DMS_Allocation_Status__c == 'Allocated'
            && allocationByProduct.size() == check.quantitiesByProduct.size();
        if (alreadyAllocated) {
            for (Id productId : check.quantitiesByProduct.keySet()) {
                DMS_Order_Allocation__c allocation = allocationByProduct.get(productId);
                if (allocation == null || allocation.Warehouse__c != warehouseId
                    || allocation.Allocated_Quantity__c != check.quantitiesByProduct.get(productId)
                    || allocation.Allocation_Status__c != 'Allocated') {
                    alreadyAllocated = false;
                    break;
                }
            }
        }
        if (!check.canReserve) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'The selected warehouse cannot allocate every order line. No allocation was recorded.',
                'status' => 'insufficient',
                'orderId' => salesOrder.Id,
                'warehouseId' => warehouseId,
                'canAllocate' => false,
                'lines' => check.lines
            });
            return;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            List<DMS_Order_Allocation__c> recordsToInsert =
                new List<DMS_Order_Allocation__c>();
            List<DMS_Order_Allocation__c> recordsToUpdate =
                new List<DMS_Order_Allocation__c>();
            for (Id productId : check.quantitiesByProduct.keySet()) {
                Decimal quantity = check.quantitiesByProduct.get(productId);
                DMS_Order_Allocation__c allocation = allocationByProduct.get(productId);
                if (allocation == null) {
                    recordsToInsert.add(new DMS_Order_Allocation__c(
                        Order__c = salesOrder.Id,
                        Product__c = productId,
                        Warehouse__c = warehouseId,
                        Allocated_Quantity__c = quantity,
                        Allocation_Key__c = String.valueOf(salesOrder.Id) + ':' + String.valueOf(productId),
                        Allocation_Status__c = 'Allocated'
                    ));
                } else {
                    allocation.Warehouse__c = warehouseId;
                    allocation.Allocated_Quantity__c = quantity;
                    allocation.Allocation_Status__c = 'Allocated';
                    recordsToUpdate.add(allocation);
                }
            }
            for (DMS_Order_Allocation__c allocation : existingAllocations) {
                if (!check.quantitiesByProduct.containsKey(allocation.Product__c)
                    && allocation.Allocation_Status__c != 'Released') {
                    allocation.Allocation_Status__c = 'Released';
                    recordsToUpdate.add(allocation);
                }
            }
            if (!recordsToInsert.isEmpty()) insert recordsToInsert;
            if (!recordsToUpdate.isEmpty()) update recordsToUpdate;

            salesOrder.DMS_Fulfillment_Warehouse__c = warehouseId;
            salesOrder.DMS_Allocation_Status__c = 'Allocated';
            update salesOrder;

            Map<String, Object> result = new Map<String, Object>{
                'success' => true,
                'status' => 'allocated',
                'allocationStatus' => 'Allocated',
                'message' => 'Order quantities were allocated to the selected warehouse. No stock was deducted or reserved.',
                'orderId' => salesOrder.Id,
                'warehouseId' => warehouseId,
                'canAllocate' => true,
                'alreadyAllocated' => alreadyAllocated,
                'lines' => check.lines,
                'allocations' => getAllocationSummaries(new Set<Id>{salesOrder.Id}).get(salesOrder.Id)
            };
            writeResponse(response, 200, result);
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR, 'DMS warehouse allocation failed: ' + error.getTypeName());
            throw new ConflictException('The warehouse allocation was not saved. Verify allocation metadata and try again.');
        }
    }

    private static void requireMatchingAllocation(
        Order salesOrder,
        Id warehouseId,
        StockCheck check
    ) {
        if (salesOrder.DMS_Fulfillment_Warehouse__c != warehouseId
            || (salesOrder.DMS_Allocation_Status__c != 'Allocated'
                && salesOrder.DMS_Allocation_Status__c != 'Reserved')) {
            throw new ConflictException('Allocate this order to the selected warehouse before reserving stock.');
        }
        Map<Id, Decimal> allocatedByProduct = new Map<Id, Decimal>();
        for (DMS_Order_Allocation__c allocation : [
            SELECT Product__c, Warehouse__c, Allocated_Quantity__c, Allocation_Status__c
            FROM DMS_Order_Allocation__c
            WHERE Order__c = :salesOrder.Id
              AND Allocation_Status__c IN ('Allocated', 'Reserved')
        ]) {
            if (allocation.Warehouse__c != warehouseId
                || (allocation.Allocation_Status__c != 'Allocated'
                    && allocation.Allocation_Status__c != 'Reserved')) {
                throw new ConflictException('The order allocation does not match the selected warehouse.');
            }
            allocatedByProduct.put(
                allocation.Product__c,
                (allocatedByProduct.containsKey(allocation.Product__c)
                    ? allocatedByProduct.get(allocation.Product__c)
                    : 0) + allocation.Allocated_Quantity__c
            );
        }
        if (allocatedByProduct.size() != check.quantitiesByProduct.size()) {
            throw new ConflictException('The order allocation is incomplete. Allocate the order again before reserving stock.');
        }
        for (Id productId : check.quantitiesByProduct.keySet()) {
            if (allocatedByProduct.get(productId) != check.quantitiesByProduct.get(productId)) {
                throw new ConflictException('The allocated quantities no longer match the order lines. Reallocate the order before reserving stock.');
            }
        }
    }

    private static void reserveStock(
        Account distributor,
        Order salesOrder,
        Id warehouseId,
        StockCheck check,
        Map<String, Object> payload,
        RestResponse response
    ) {
        ensureTransactionType('Stock Reservation');
        ensureTransactionType('Stock Release');

        String idempotencyKey = stringValue(payload.get('idempotencyKey'));
        if (String.isBlank(idempotencyKey) || idempotencyKey.length() > 40
            || !Pattern.matches('^[A-Za-z0-9_-]+$', idempotencyKey)) {
            throw new RequestException('A unique alphanumeric idempotency key is required.');
        }
        String reservationPrefix = 'DMS-RES-' + String.valueOf(salesOrder.Id) + '-';
        String reservationReference = reservationPrefix + idempotencyKey;
        validateLength(
            reservationReference,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c.getLength()
        );

        List<Inventory_Transaction__c> sameRequest = [
            SELECT Id, Transaction_Type__c, Inventory__c, Inventory__r.Product__c,
                   Inventory__r.Warehouse__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = :reservationReference
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
        ];
        if (!sameRequest.isEmpty()) {
            Boolean sameReservation = sameRequest.size() == check.quantitiesByProduct.size();
            Set<Id> productsSeen = new Set<Id>();
            for (Inventory_Transaction__c stockTransaction : sameRequest) {
                Id productId = stockTransaction.Inventory__r.Product__c;
                if (stockTransaction.Transaction_Type__c != 'Stock Reservation'
                    || stockTransaction.Inventory__r.Warehouse__c != warehouseId
                    || !check.quantitiesByProduct.containsKey(productId)
                    || stockTransaction.Quantity__c != check.quantitiesByProduct.get(productId)
                    || productsSeen.contains(productId)) {
                    sameReservation = false;
                }
                productsSeen.add(productId);
            }
            if (!sameReservation) {
                throw new ConflictException('This idempotency key has already been used for a different or completed reservation.');
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => 'reserved',
                'message' => 'This order reservation was already recorded.',
                'orderId' => salesOrder.Id,
                'warehouseId' => warehouseId,
                'allocationStatus' => salesOrder.DMS_Allocation_Status__c,
                'allocations' => getAllocationSummaries(new Set<Id>{salesOrder.Id})
                    .get(salesOrder.Id),
                'alreadyProcessed' => true
            });
            return;
        }

        Set<String> reservationTypes = new Set<String>{'Stock Reservation', 'Stock Release'};
        String referencePattern = reservationPrefix + '%';
        Map<String, Decimal> activeByInventory = new Map<String, Decimal>();
        for (Inventory_Transaction__c stockTransaction : [
            SELECT Inventory__c, Reference_Number__c, Transaction_Type__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :referencePattern
              AND Transaction_Type__c IN :reservationTypes
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
        ]) {
            String key = stockTransaction.Reference_Number__c + ':' + stockTransaction.Inventory__c;
            Decimal current = activeByInventory.containsKey(key) ? activeByInventory.get(key) : 0;
            Decimal quantity = stockTransaction.Quantity__c == null ? 0 : stockTransaction.Quantity__c;
            activeByInventory.put(
                key,
                current + (stockTransaction.Transaction_Type__c == 'Stock Reservation' ? quantity : -quantity)
            );
        }
        for (Decimal activeQuantity : activeByInventory.values()) {
            if (activeQuantity < 0) {
                throw new ConflictException('The reservation ledger is inconsistent. Contact your administrator.');
            }
            if (activeQuantity > 0) {
                throw new ConflictException('This order already has an active stock reservation. Release it before reserving again.');
            }
        }
        if (!check.canReserve) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => 'Insufficient stock. No quantities were reserved.',
                'orderId' => salesOrder.Id,
                'warehouseId' => warehouseId,
                'canReserve' => false,
                'lines' => check.lines
            });
            return;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            List<Inventory_Transaction__c> transactions = new List<Inventory_Transaction__c>();
            for (Id productId : check.quantitiesByProduct.keySet()) {
                Decimal quantity = check.quantitiesByProduct.get(productId);
                Inventory__c inventory = check.inventoryByProduct.get(productId);
                inventory.Available_Quantity__c -= quantity;
                inventory.Reserved_Quantity__c =
                    (inventory.Reserved_Quantity__c == null ? 0 : inventory.Reserved_Quantity__c) + quantity;
                transactions.add(new Inventory_Transaction__c(
                    Inventory__c = inventory.Id,
                    Transaction_Type__c = 'Stock Reservation',
                    Quantity__c = quantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = reservationReference,
                    Transaction_Description__c = 'Reservation for order ' + salesOrder.OrderNumber
                ));
            }
            update check.inventoryByProduct.values();
            insert transactions;
            List<DMS_Order_Allocation__c> allocations = [
                SELECT Id, Allocation_Status__c
                FROM DMS_Order_Allocation__c
                WHERE Order__c = :salesOrder.Id
                  AND Allocation_Status__c = 'Allocated'
                FOR UPDATE
            ];
            for (DMS_Order_Allocation__c allocation : allocations) {
                allocation.Allocation_Status__c = 'Reserved';
            }
            if (!allocations.isEmpty()) update allocations;
            salesOrder.DMS_Allocation_Status__c = 'Reserved';
            update salesOrder;
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => 'reserved',
                'message' => 'Stock reserved for this order.',
                'orderId' => salesOrder.Id,
                'warehouseId' => warehouseId,
                'lines' => check.lines,
                'allocationStatus' => 'Reserved',
                'allocations' => getAllocationSummaries(new Set<Id>{salesOrder.Id})
                    .get(salesOrder.Id),
                'alreadyProcessed' => false
            });
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR, 'DMS stock reservation failed: ' + error.getTypeName());
            throw new ConflictException('The reservation was not saved. Check the inventory transaction configuration and retry.');
        }
    }

    private static void releaseStockReservation(
        Account distributor,
        Order salesOrder,
        RestResponse response
    ) {
        if (![SELECT Id FROM DMS_Invoice__c
              WHERE Secondary_Order__c = :salesOrder.Id AND Status__c = 'Posted'
              LIMIT 1].isEmpty()) {
            throw new ConflictException('Stock cannot be released after an invoice has been posted.');
        }
        ensureTransactionType('Stock Reservation');
        ensureTransactionType('Stock Release');
        String referencePattern = 'DMS-RES-' + String.valueOf(salesOrder.Id) + '-%';
        Map<String, Decimal> activeByReferenceInventory = new Map<String, Decimal>();
        Map<String, Id> inventoryByReferenceInventory = new Map<String, Id>();
        for (Inventory_Transaction__c stockTransaction : [
            SELECT Inventory__c, Reference_Number__c, Transaction_Type__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :referencePattern
              AND Transaction_Type__c IN ('Stock Reservation', 'Stock Release')
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
        ]) {
            String key = stockTransaction.Reference_Number__c + ':' + stockTransaction.Inventory__c;
            Decimal current = activeByReferenceInventory.containsKey(key)
                ? activeByReferenceInventory.get(key)
                : 0;
            Decimal quantity = stockTransaction.Quantity__c == null ? 0 : stockTransaction.Quantity__c;
            activeByReferenceInventory.put(
                key,
                current + (stockTransaction.Transaction_Type__c == 'Stock Reservation' ? quantity : -quantity)
            );
            inventoryByReferenceInventory.put(key, stockTransaction.Inventory__c);
        }

        Map<Id, Decimal> releaseByInventory = new Map<Id, Decimal>();
        for (String key : activeByReferenceInventory.keySet()) {
            Decimal quantity = activeByReferenceInventory.get(key);
            if (quantity < 0) {
                throw new ConflictException('The reservation ledger is inconsistent. Contact your administrator.');
            }
            if (quantity > 0) {
                Id inventoryId = inventoryByReferenceInventory.get(key);
                releaseByInventory.put(
                    inventoryId,
                    (releaseByInventory.containsKey(inventoryId) ? releaseByInventory.get(inventoryId) : 0) + quantity
                );
            }
        }
        if (releaseByInventory.isEmpty()) {
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => 'notReserved',
                'message' => 'There is no active reservation to release.',
                'orderId' => salesOrder.Id,
                'allocationStatus' => salesOrder.DMS_Allocation_Status__c,
                'allocations' => getAllocationSummaries(new Set<Id>{salesOrder.Id})
                    .get(salesOrder.Id),
                'alreadyProcessed' => true
            });
            return;
        }

        List<Inventory__c> inventoryRecords = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c, Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Id IN :releaseByInventory.keySet()
            FOR UPDATE
        ];
        if (inventoryRecords.size() != releaseByInventory.size()) {
            throw new ConflictException('A reserved inventory balance is missing. No reservation was released.');
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            List<Inventory_Transaction__c> releases = new List<Inventory_Transaction__c>();
            for (Inventory__c inventory : inventoryRecords) {
                Decimal quantity = releaseByInventory.get(inventory.Id);
                Decimal reserved = inventory.Reserved_Quantity__c == null ? 0 : inventory.Reserved_Quantity__c;
                if (reserved < quantity) {
                    throw new ConflictException('The inventory balance no longer matches its reservation ledger.');
                }
                inventory.Reserved_Quantity__c = reserved - quantity;
                inventory.Available_Quantity__c =
                    (inventory.Available_Quantity__c == null ? 0 : inventory.Available_Quantity__c) + quantity;
            }
            for (String key : activeByReferenceInventory.keySet()) {
                Decimal quantity = activeByReferenceInventory.get(key);
                if (quantity <= 0) continue;
                Integer separatorIndex = key.indexOf(':');
                releases.add(new Inventory_Transaction__c(
                    Inventory__c = inventoryByReferenceInventory.get(key),
                    Transaction_Type__c = 'Stock Release',
                    Quantity__c = quantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = key.substring(0, separatorIndex),
                    Transaction_Description__c = 'Reservation released for order ' + salesOrder.OrderNumber
                ));
            }
            update inventoryRecords;
            insert releases;
            List<DMS_Order_Allocation__c> allocations = [
                SELECT Id, Allocation_Status__c
                FROM DMS_Order_Allocation__c
                WHERE Order__c = :salesOrder.Id
                  AND Allocation_Status__c = 'Reserved'
                FOR UPDATE
            ];
            for (DMS_Order_Allocation__c allocation : allocations) {
                allocation.Allocation_Status__c = 'Allocated';
            }
            if (!allocations.isEmpty()) {
                update allocations;
                salesOrder.DMS_Allocation_Status__c = 'Allocated';
                update salesOrder;
            }
            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'status' => 'released',
                'message' => 'The active order reservation was released.',
                'orderId' => salesOrder.Id,
                'allocationStatus' => salesOrder.DMS_Allocation_Status__c,
                'allocations' => getAllocationSummaries(new Set<Id>{salesOrder.Id})
                    .get(salesOrder.Id),
                'alreadyProcessed' => false
            });
        } catch (ConflictException error) {
            Database.rollback(savepoint);
            throw error;
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR, 'DMS stock reservation release failed: ' + error.getTypeName());
            throw new ConflictException('The reservation could not be released. Check inventory configuration and retry.');
        }
    }

    private static Map<String, Object> reservationStatus(
        Account distributor,
        Order salesOrder
    ) {
        String referencePattern = 'DMS-RES-' + String.valueOf(salesOrder.Id) + '-%';
        Map<String, Decimal> activeByReferenceInventory = new Map<String, Decimal>();
        Map<String, Id> inventoryByReferenceInventory = new Map<String, Id>();
        Boolean hasReservationHistory = false;
        Boolean hasConsumedReservation = false;
        Datetime reservationDate;
        String reservedBy;
        Datetime releaseDate;
        String releasedBy;
        for (Inventory_Transaction__c stockTransaction : [
            SELECT Inventory__c, Reference_Number__c, Transaction_Type__c, Quantity__c,
                   Transaction_Date__c, CreatedDate, CreatedBy.Name, DMS_Invoice__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :referencePattern
              AND Transaction_Type__c IN ('Stock Reservation', 'Stock Release')
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ORDER BY CreatedDate, Id
        ]) {
            String key = stockTransaction.Reference_Number__c + ':' + stockTransaction.Inventory__c;
            Decimal current = activeByReferenceInventory.containsKey(key)
                ? activeByReferenceInventory.get(key)
                : 0;
            Decimal quantity = stockTransaction.Quantity__c == null ? 0 : stockTransaction.Quantity__c;
            Datetime transactionDate = stockTransaction.Transaction_Date__c == null
                ? stockTransaction.CreatedDate
                : stockTransaction.Transaction_Date__c;
            if (stockTransaction.Transaction_Type__c == 'Stock Reservation') {
                hasReservationHistory = true;
                reservationDate = transactionDate;
                reservedBy = stockTransaction.CreatedBy == null
                    ? null
                    : stockTransaction.CreatedBy.Name;
            } else {
                releaseDate = transactionDate;
                releasedBy = stockTransaction.CreatedBy == null
                    ? null
                    : stockTransaction.CreatedBy.Name;
                if (stockTransaction.DMS_Invoice__c != null) {
                    hasConsumedReservation = true;
                }
            }
            activeByReferenceInventory.put(
                key,
                current + (stockTransaction.Transaction_Type__c == 'Stock Reservation' ? quantity : -quantity)
            );
            inventoryByReferenceInventory.put(key, stockTransaction.Inventory__c);
        }
        Map<Id, Decimal> activeByInventory = new Map<Id, Decimal>();
        for (String key : activeByReferenceInventory.keySet()) {
            Decimal quantity = activeByReferenceInventory.get(key);
            if (quantity < 0) {
                throw new ConflictException('The reservation ledger is inconsistent. Contact your administrator.');
            }
            if (quantity > 0) {
                Id inventoryId = inventoryByReferenceInventory.get(key);
                activeByInventory.put(
                    inventoryId,
                    (activeByInventory.containsKey(inventoryId) ? activeByInventory.get(inventoryId) : 0) + quantity
                );
            }
        }
        List<Map<String, Object>> reservations = new List<Map<String, Object>>();
        if (!activeByInventory.isEmpty()) {
            for (Inventory__c inventory : [
                SELECT Id, Product__c, Product__r.Name, Warehouse__c, Warehouse__r.Name
                FROM Inventory__c
                WHERE Id IN :activeByInventory.keySet()
            ]) {
                reservations.add(new Map<String, Object>{
                    'inventoryId' => inventory.Id,
                    'productId' => inventory.Product__c,
                    'productName' => inventory.Product__r == null ? null : inventory.Product__r.Name,
                    'warehouseId' => inventory.Warehouse__c,
                    'warehouseName' => inventory.Warehouse__r == null ? null : inventory.Warehouse__r.Name,
                    'quantity' => activeByInventory.get(inventory.Id),
                    'reservedAt' => reservationDate,
                    'reservedBy' => reservedBy
                });
            }
        }
        return new Map<String, Object>{
            'success' => true,
            'orderId' => salesOrder.Id,
            'status' => !reservations.isEmpty()
                ? 'reserved'
                : hasConsumedReservation
                    ? 'consumed'
                    : hasReservationHistory
                        ? 'released'
                        : 'notReserved',
            'reservationDate' => reservationDate,
            'reservedBy' => reservedBy,
            'releaseDate' => releaseDate,
            'releasedBy' => releasedBy,
            'allocationStatus' => String.isBlank(salesOrder.DMS_Allocation_Status__c)
                ? 'Not Allocated'
                : salesOrder.DMS_Allocation_Status__c,
            'warehouseId' => salesOrder.DMS_Fulfillment_Warehouse__c,
            'allocationLines' => getAllocationSummaries(new Set<Id>{salesOrder.Id})
                .get(salesOrder.Id),
            'reservations' => reservations
        };
    }

    private static void ensureTransactionType(String type) {
        Schema.DescribeFieldResult description =
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c;
        if (description.getType() == Schema.DisplayType.Picklist) {
            for (Schema.PicklistEntry option : description.getPicklistValues()) {
                if (option.isActive() && option.getValue() == type) return;
            }
            throw new ConfigurationException(
                'Add the "' + type + '" value to Inventory_Transaction__c.Transaction_Type__c before using stock reservations.'
            );
        }
    }

    private static void requireReservationReadPermissions() {
        if (UserInfo.getUserType() == 'Guest') return;
        if (!Schema.sObjectType.Inventory__c.isAccessible()
            || !Schema.sObjectType.Inventory_Transaction__c.isAccessible()
            || !Schema.sObjectType.DMS_Order_Allocation__c.isAccessible()) {
            throw new ReservationAccessException(
                'You do not have permission to view stock reservation details.'
            );
        }
        for (Schema.DescribeFieldResult field : new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Product__c,
            Schema.sObjectType.Inventory__c.fields.Warehouse__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Inventory__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Quantity__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Date__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.DMS_Invoice__c,
            Schema.sObjectType.DMS_Order_Allocation__c.fields.Allocation_Status__c
        }) {
            if (!field.isAccessible()) {
                throw new ReservationAccessException(
                    'You do not have permission to view stock reservation details.'
                );
            }
        }
    }

    private static void requireReservationWritePermissions() {
        if (UserInfo.getUserType() == 'Guest') return;
        if (!Schema.sObjectType.Inventory__c.isUpdateable()
            || !Schema.sObjectType.Inventory_Transaction__c.isCreateable()
            || !Schema.sObjectType.DMS_Order_Allocation__c.isUpdateable()
            || !Schema.sObjectType.Order.isUpdateable()) {
            throw new ReservationAccessException(
                'You do not have permission to change stock reservations.'
            );
        }
        for (Schema.DescribeFieldResult field : new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
            Schema.sObjectType.DMS_Order_Allocation__c.fields.Allocation_Status__c,
            Schema.sObjectType.Order.fields.DMS_Allocation_Status__c
        }) {
            if (!field.isUpdateable()) {
                throw new ReservationAccessException(
                    'You do not have permission to change stock reservations.'
                );
            }
        }
        for (Schema.DescribeFieldResult field : new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory_Transaction__c.fields.Inventory__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Quantity__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Date__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c
        }) {
            if (!field.isCreateable()) {
                throw new ReservationAccessException(
                    'You do not have permission to change stock reservations.'
                );
            }
        }
    }

    private static void validateLength(String value, Integer maxLength) {
        if (value.length() > maxLength) {
            throw new RequestException('The idempotency key is too long for the inventory transaction reference.');
        }
    }

    private static Map<Id, Map<String, Object>> getApprovalSummaries(Set<Id> orderIds) {
        Map<Id, Map<String, Object>> summaries = new Map<Id, Map<String, Object>>();
        if (orderIds == null || orderIds.isEmpty()) return summaries;

        Map<Id, ProcessInstance> latestByOrder = new Map<Id, ProcessInstance>();
        Set<Id> processInstanceIds = new Set<Id>();
        for (ProcessInstance instance : [
            SELECT Id, TargetObjectId, Status, CreatedDate, CompletedDate
            FROM ProcessInstance
            WHERE TargetObjectId IN :orderIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!latestByOrder.containsKey(instance.TargetObjectId)) {
                latestByOrder.put(instance.TargetObjectId, instance);
                processInstanceIds.add(instance.Id);
            }
        }

        Map<Id, ProcessInstanceStep> finalSteps = new Map<Id, ProcessInstanceStep>();
        Set<Id> actorIds = new Set<Id>();
        if (!processInstanceIds.isEmpty()) {
            for (ProcessInstanceStep step : [
                SELECT ProcessInstanceId, StepStatus, ActorId, Comments, CreatedDate
                FROM ProcessInstanceStep
                WHERE ProcessInstanceId IN :processInstanceIds
                  AND StepStatus IN ('Approved', 'Rejected')
                ORDER BY CreatedDate DESC
            ]) {
                if (!finalSteps.containsKey(step.ProcessInstanceId)) {
                    finalSteps.put(step.ProcessInstanceId, step);
                    if (step.ActorId != null && String.valueOf(step.ActorId).startsWith('005')) {
                        actorIds.add(step.ActorId);
                    }
                }
            }
        }
        Map<Id, String> actorNames = new Map<Id, String>();
        if (!actorIds.isEmpty()) {
            for (User actor : [SELECT Id, Name FROM User WHERE Id IN :actorIds]) {
                actorNames.put(actor.Id, actor.Name);
            }
        }

        for (Id orderId : orderIds) {
            ProcessInstance instance = latestByOrder.get(orderId);
            String status = instance == null
                ? 'Not Submitted'
                : approvalStatusLabel(instance.Status);
            ProcessInstanceStep finalStep = instance == null
                ? null
                : finalSteps.get(instance.Id);
            summaries.put(orderId, new Map<String, Object>{
                'approvalStatus' => status,
                'approvalSubmittedDate' => instance == null ? null : instance.CreatedDate,
                'approvalDate' => instance == null ? null : instance.CompletedDate,
                'approvedBy' => status == 'Approved' && finalStep != null
                    ? actorNames.get(finalStep.ActorId)
                    : null,
                'rejectionReason' => status == 'Rejected' && finalStep != null
                    ? finalStep.Comments
                    : null
            });
        }
        return summaries;
    }

    private static String approvalStatusLabel(String processStatus) {
        if (processStatus == 'Pending') return 'Pending Approval';
        if (processStatus == 'Approved') return 'Approved';
        if (processStatus == 'Rejected') return 'Rejected';
        if (processStatus == 'Removed') return 'Recalled';
        return 'Not Submitted';
    }

    private static OrderCalculation calculateOrder(
        Account distributor,
        String salesType,
        Id retailerId,
        Object linePayload,
        Object selectedSchemePayload
    ) {
        Account retailer = validateRetailer(distributor, salesType, retailerId);
        List<OrderLineInput> requestedLines = parseLines(linePayload);
        Set<Id> selectedSchemeIds = parseSelectedSchemeIds(selectedSchemePayload);
        Pricebook2 pricebook = getChannelPricebook(salesType);
        Set<Id> pricebookEntryIds = new Set<Id>();
        for (OrderLineInput requestedLine : requestedLines) {
            pricebookEntryIds.add(requestedLine.pricebookEntryId);
        }

        Map<Id, PricebookEntry> entriesById = new Map<Id, PricebookEntry>([
            SELECT Id, Pricebook2Id, UnitPrice, Product2Id, Product2.Name,
                   Product2.ProductCode, Product2.Description, Product2.DisplayUrl,
                   Product2.IsActive, Product2.DMS_Tax_Rate__c,
                   Product2.SFA_Product__c, Product2.QuantityUnitOfMeasure,
                   Unit_of_Measure__c,
                   Unit_Conversion_Factor__c
            FROM PricebookEntry
            WHERE Id IN :pricebookEntryIds
              AND Pricebook2Id = :pricebook.Id
              AND IsActive = true
              AND Product2.IsActive = true
              AND Product2.SFA_Product__c = true
        ]);
        if (entriesById.size() != requestedLines.size()) {
            throw new RequestException('One or more selected products are no longer available for this sales channel.');
        }

        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry entry : entriesById.values()) {
            productIds.add(entry.Product2Id);
            validatePricebookEntry(entry);
        }
        Map<Id, Map<String, Decimal>> unitFactors = getUnitFactors(productIds);
        Map<Id, List<Scheme_Product__c>> availableSchemesByProduct =
            getActiveSchemes(productIds, salesType);
        Map<Id, List<Scheme_Product__c>> selectedSchemesByProduct =
            selectSchemes(selectedSchemeIds, availableSchemesByProduct);
        OrderCalculation calculation = new OrderCalculation(pricebook.Id, retailer);

        for (OrderLineInput requestedLine : requestedLines) {
            PricebookEntry entry = entriesById.get(requestedLine.pricebookEntryId);
            Map<String, Decimal> productFactors = unitFactors.get(entry.Product2Id);
            Decimal salesFactor = productFactors == null
                ? null
                : productFactors.get(normalizeUnit(entry.Unit_of_Measure__c));
            if (salesFactor == null || salesFactor != entry.Unit_Conversion_Factor__c) {
                throw new ConflictException(
                    'The unit conversion for ' + entry.Product2.Name + ' is missing or inconsistent.'
                );
            }

            CalculatedLine line = calculateLine(
                entry,
                requestedLine.quantity,
                salesFactor,
                productFactors,
                selectedSchemesByProduct.get(entry.Product2Id)
            );
            calculation.lines.add(line);
            calculation.subtotal += line.grossAmount;
            calculation.discount += line.discountAmount;
            calculation.taxTotal += line.taxAmount;
            calculation.netAmount += line.netAmount;
            calculation.total += line.lineTotal;
            calculation.previewLines.add(line.preview);
        }

        calculation.subtotal = calculation.subtotal.setScale(2);
        calculation.discount = calculation.discount.setScale(2);
        calculation.taxTotal = calculation.taxTotal.setScale(2);
        calculation.total = calculation.total.setScale(2);
        calculation.preview = new Map<String, Object>{
            'salesType' => salesType,
            'customerName' => salesType == 'Secondary' ? retailer.Name : distributor.Name,
            'distributorName' => distributor.Name,
            'retailerId' => retailer == null ? null : retailer.Id,
            'retailerName' => retailer == null ? null : retailer.Name,
            'pricebookId' => pricebook.Id,
            'pricebookName' => pricebook.Name,
            'lines' => calculation.previewLines,
            'subtotal' => calculation.subtotal,
            'discount' => calculation.discount,
            'taxableAmount' => calculation.netAmount,
            'totalTax' => calculation.taxTotal,
            'totalAmount' => calculation.netAmount,
            'totalWithTax' => calculation.total
        };
        return calculation;
    }

    private static CalculatedLine calculateLine(
        PricebookEntry entry,
        Decimal requestedQuantity,
        Decimal salesFactor,
        Map<String, Decimal> productFactors,
        List<Scheme_Product__c> schemes
    ) {
        Decimal taxRate = entry.Product2.DMS_Tax_Rate__c == null
            ? 0
            : entry.Product2.DMS_Tax_Rate__c;
        if (taxRate < 0 || taxRate > 100) {
            throw new ConflictException(
                'The configured tax rate for ' + entry.Product2.Name + ' is invalid.'
            );
        }

        Scheme_Product__c selectedScheme;
        Decimal selectedFreeQuantity = 0;
        Decimal selectedSchemeDiscount = 0;
        Decimal requestedBaseQuantity = requestedQuantity * salesFactor;
        if (schemes != null) {
            for (Scheme_Product__c scheme : schemes) {
                if (scheme.Minimum_Quantity__c == null || scheme.Minimum_Quantity__c <= 0
                    || (scheme.Free_Quantity__c != null && scheme.Free_Quantity__c < 0)) {
                    throw new ConflictException(
                        'Scheme "' + scheme.Scheme__r.Scheme_Name__c
                        + '" has invalid quantity configuration.'
                    );
                }
                String minimumUnit = String.isBlank(scheme.Minimum_Unit__c)
                    ? entry.Unit_of_Measure__c
                    : scheme.Minimum_Unit__c;
                String freeUnit = String.isBlank(scheme.Free_Unit__c)
                    ? entry.Unit_of_Measure__c
                    : scheme.Free_Unit__c;
                Decimal minimumFactor = productFactors.get(normalizeUnit(minimumUnit));
                Decimal freeFactor = productFactors.get(normalizeUnit(freeUnit));
                if (minimumFactor == null || freeFactor == null) {
                    throw new ConflictException(
                        'Scheme "' + scheme.Scheme__r.Scheme_Name__c
                        + '" uses a unit that is not configured for '
                        + entry.Product2.Name + '.'
                    );
                }

                Decimal minimumBaseQuantity = scheme.Minimum_Quantity__c * minimumFactor;
                Decimal qualifyingGroups = (requestedBaseQuantity / minimumBaseQuantity)
                    .setScale(0, RoundingMode.DOWN);
                if (qualifyingGroups <= 0) {
                    throw new ConflictException(
                        'The order quantity does not meet the minimum for selected scheme "'
                        + scheme.Scheme__r.Scheme_Name__c + '".'
                    );
                }
                Decimal freeBaseQuantity = qualifyingGroups
                    * (scheme.Free_Quantity__c == null ? 0 : scheme.Free_Quantity__c)
                    * freeFactor;
                Decimal unroundedFreeQuantity = freeBaseQuantity / salesFactor;
                Decimal freeQuantity = unroundedFreeQuantity.setScale(2, RoundingMode.DOWN);
                if (freeQuantity != unroundedFreeQuantity) {
                    throw new ConflictException(
                        'Scheme "' + scheme.Scheme__r.Scheme_Name__c
                        + '" grants a quantity that cannot be represented '
                        + 'in the configured sales unit for ' + entry.Product2.Name + '.'
                    );
                }

                Decimal requestedAmount = (entry.UnitPrice * requestedQuantity).setScale(2);
                Decimal percentageDiscount = requestedAmount
                    * (scheme.Discount_Percentage__c == null
                        ? 0
                        : scheme.Discount_Percentage__c) / 100;
                Decimal fixedDiscount = (scheme.Discount_Amount__c == null
                    ? 0
                    : scheme.Discount_Amount__c) * qualifyingGroups;
                Decimal schemeDiscount = Math.min(
                    requestedAmount,
                    (percentageDiscount + fixedDiscount).setScale(2)
                );
                if (freeQuantity <= 0 && schemeDiscount <= 0) {
                    throw new ConflictException(
                        'Selected scheme "' + scheme.Scheme__r.Scheme_Name__c
                        + '" has no applicable benefit for this order.'
                    );
                }
                selectedScheme = scheme;
                selectedFreeQuantity = freeQuantity;
                selectedSchemeDiscount = schemeDiscount;
            }
        }

        Decimal paidAmount = (entry.UnitPrice * requestedQuantity).setScale(2);
        Decimal grossAmount = (entry.UnitPrice * (requestedQuantity + selectedFreeQuantity))
            .setScale(2);
        Decimal paidUnitPrice = selectedSchemeDiscount > 0
            ? ((paidAmount - selectedSchemeDiscount) / requestedQuantity)
                .setScale(2, RoundingMode.HALF_UP)
            : entry.UnitPrice;
        Decimal netAmount = (paidUnitPrice * requestedQuantity).setScale(2);
        Decimal appliedSchemeDiscount = (paidAmount - netAmount).setScale(2);
        Decimal discountAmount = ((entry.UnitPrice * selectedFreeQuantity)
            + appliedSchemeDiscount).setScale(2);
        Decimal taxAmount = (netAmount * taxRate / 100).setScale(2);
        CalculatedLine line = new CalculatedLine(
            entry,
            requestedQuantity,
            selectedFreeQuantity,
            salesFactor,
            selectedScheme,
            taxRate,
            paidUnitPrice,
            netAmount,
            grossAmount,
            discountAmount,
            appliedSchemeDiscount,
            taxAmount,
            netAmount + taxAmount
        );
        line.preview = new Map<String, Object>{
            'pricebookEntryId' => entry.Id,
            'productId' => entry.Product2Id,
            'productName' => entry.Product2.Name,
            'requestedQuantity' => requestedQuantity,
            'paidQuantity' => requestedQuantity,
            'freeQuantity' => selectedFreeQuantity,
            'unitPrice' => entry.UnitPrice,
            'unitOfMeasure' => entry.Unit_of_Measure__c,
            'conversionFactor' => salesFactor,
            'schemeId' => selectedScheme == null ? null : selectedScheme.Id,
            'schemeName' => selectedScheme == null
                ? null
                : selectedScheme.Scheme__r.Scheme_Name__c,
            'schemeProductId' => selectedScheme == null ? null : selectedScheme.Id,
            'subtotal' => (entry.UnitPrice * requestedQuantity).setScale(2),
            'discountAmount' => discountAmount,
            'netUnitPrice' => paidUnitPrice,
            'taxRate' => taxRate,
            'taxAmount' => taxAmount,
            'lineTotal' => netAmount
        };
        return line;
    }

    private static Map<Id, List<Scheme_Product__c>> getActiveSchemes(
        Set<Id> productIds,
        String salesType
    ) {
        Map<Id, List<Scheme_Product__c>> schemesByProduct =
            new Map<Id, List<Scheme_Product__c>>();
        if (productIds.isEmpty()) {
            return schemesByProduct;
        }
        Date today = Date.today();
        for (Scheme_Product__c scheme : [
            SELECT Id, Scheme__c, Scheme__r.Scheme_Name__c, Scheme__r.Scheme_Type__c,
                   Scheme__r.Sales_Type__c, Scheme__r.Active__c, Scheme__r.Status__c,
                   Scheme__r.Start_Date__c, Scheme__r.End_Date__c,
                   Product__c, Minimum_Quantity__c, Minimum_Unit__c,
                   Free_Quantity__c, Free_Unit__c, Discount_Percentage__c,
                   Discount_Amount__c, Priority__c, Active__c
            FROM Scheme_Product__c
            WHERE Product__c IN :productIds
              AND Active__c = true
              AND Scheme__r.Active__c = true
              AND Scheme__r.Status__c = 'Active'
              AND Scheme__r.Sales_Type__c = :salesType
              AND (Scheme__r.Start_Date__c = null OR Scheme__r.Start_Date__c <= :today)
              AND (Scheme__r.End_Date__c = null OR Scheme__r.End_Date__c >= :today)
            ORDER BY Priority__c DESC, Scheme__r.Scheme_Name__c
        ]) {
            if (!schemesByProduct.containsKey(scheme.Product__c)) {
                schemesByProduct.put(scheme.Product__c, new List<Scheme_Product__c>());
            }
            schemesByProduct.get(scheme.Product__c).add(scheme);
        }
        return schemesByProduct;
    }

    private static Map<Id, Map<String, Decimal>> getUnitFactors(Set<Id> productIds) {
        Map<Id, Map<String, Decimal>> factorsByProduct =
            new Map<Id, Map<String, Decimal>>();
        if (productIds.isEmpty()) {
            return factorsByProduct;
        }

        for (Product2 product : [
            SELECT Id, Name, QuantityUnitOfMeasure
            FROM Product2
            WHERE Id IN :productIds
        ]) {
            if (String.isBlank(product.QuantityUnitOfMeasure)) {
                throw new ConflictException(
                    'A base unit of measure must be configured for ' + product.Name + '.'
                );
            }
            factorsByProduct.put(product.Id, new Map<String, Decimal>());
            putUnitFactor(
                factorsByProduct.get(product.Id),
                product.QuantityUnitOfMeasure,
                1,
                product.Name
            );
        }

        for (PricebookEntry entry : [
            SELECT Product2Id, Product2.Name, Unit_of_Measure__c,
                   Unit_Conversion_Factor__c
            FROM PricebookEntry
            WHERE Product2Id IN :productIds
              AND IsActive = true
              AND Product2.IsActive = true
              AND Pricebook2.IsActive = true
              AND Unit_of_Measure__c != null
              AND Unit_Conversion_Factor__c > 0
        ]) {
            putUnitFactor(
                factorsByProduct.get(entry.Product2Id),
                entry.Unit_of_Measure__c,
                entry.Unit_Conversion_Factor__c,
                entry.Product2.Name
            );
        }
        return factorsByProduct;
    }

    private static void putUnitFactor(
        Map<String, Decimal> productFactors,
        String unit,
        Decimal factor,
        String productName
    ) {
        String key = normalizeUnit(unit);
        if (String.isBlank(key) || factor == null || factor <= 0) {
            throw new ConflictException(
                'A positive conversion factor is required for ' + productName + '.'
            );
        }
        if (productFactors.containsKey(key) && productFactors.get(key) != factor) {
            throw new ConflictException(
                'The conversion factor for ' + unit + ' is inconsistent across price books for '
                + productName + '.'
            );
        }
        productFactors.put(key, factor);
    }

    private static void validatePricebookEntry(PricebookEntry entry) {
        if (entry.UnitPrice == null || entry.UnitPrice <= 0) {
            throw new ConflictException(
                'A positive price must be configured for ' + entry.Product2.Name + '.'
            );
        }
        if (String.isBlank(entry.Unit_of_Measure__c)
            || entry.Unit_Conversion_Factor__c == null
            || entry.Unit_Conversion_Factor__c <= 0) {
            throw new ConflictException(
                'A sales unit and positive conversion factor must be configured for '
                + entry.Product2.Name + '.'
            );
        }
        if (String.isBlank(entry.Product2.QuantityUnitOfMeasure)) {
            throw new ConflictException(
                'A base unit of measure must be configured for ' + entry.Product2.Name + '.'
            );
        }
    }

    private static Pricebook2 getChannelPricebook(String salesType) {
        List<Pricebook2> pricebooks = [
            SELECT Id, Name
            FROM Pricebook2
            WHERE IsActive = true
              AND Sales_Type__c = :salesType
            ORDER BY Name
            LIMIT 2
        ];
        if (pricebooks.isEmpty()) {
            throw new ConflictException(
                'No active ' + salesType.toLowerCase()
                + ' sales price book is configured.'
            );
        }
        if (pricebooks.size() > 1) {
            throw new ConflictException(
                'More than one active ' + salesType.toLowerCase()
                + ' sales price book is configured. Keep one active price book per channel.'
            );
        }
        return pricebooks[0];
    }

    private static Account validateRetailer(
        Account distributor,
        String salesType,
        Id retailerId
    ) {
        if (salesType == 'Primary') {
            if (retailerId != null) {
                throw new RequestException('A Primary order cannot select a retailer.');
            }
            return null;
        }
        if (retailerId == null) {
            throw new RequestException('Select an authorized retailer for the Secondary order.');
        }
        List<Account> retailers = [
            SELECT Id, Name, Distributor__c, Account_Category__c, Active__c
            FROM Account
            WHERE Id = :retailerId
              AND Distributor__c = :distributor.Id
              AND Account_Category__c = 'Outlet'
              AND Active__c = 'Yes'
            LIMIT 1
        ];
        if (retailers.isEmpty()) {
            throw new RequestException(
                'The selected retailer is inactive or is not assigned to your distributor.'
            );
        }
        return retailers[0];
    }

    private static List<OrderLineInput> parseLines(Object linePayload) {
        if (!(linePayload instanceof List<Object>)) {
            throw new RequestException('At least one order line is required.');
        }
        List<Object> rawLines = (List<Object>) linePayload;
        if (rawLines.isEmpty() || rawLines.size() > MAX_ORDER_LINES) {
            throw new RequestException(
                'An order must contain between 1 and ' + MAX_ORDER_LINES + ' product lines.'
            );
        }
        Set<Id> selectedEntryIds = new Set<Id>();
        List<OrderLineInput> lines = new List<OrderLineInput>();
        for (Object rawLine : rawLines) {
            if (!(rawLine instanceof Map<String, Object>)) {
                throw new RequestException('Each order line must contain a product and quantity.');
            }
            Map<String, Object> lineData = (Map<String, Object>) rawLine;
            Id entryId = parseOptionalId(lineData.get('pricebookEntryId'));
            Decimal quantity = parseDecimal(lineData.get('quantity'));
            if (entryId == null || entryId.getSObjectType() != PricebookEntry.SObjectType) {
                throw new RequestException('Each order line must select a valid price book entry.');
            }
            if (quantity == null || quantity <= 0 || quantity > MAX_ORDER_QUANTITY
                || quantity != quantity.setScale(2, RoundingMode.DOWN)) {
                throw new RequestException(
                    'Order quantities must be positive and may contain up to two decimal places.'
                );
            }
            if (selectedEntryIds.contains(entryId)) {
                throw new RequestException('Each product may appear only once in an order.');
            }
            selectedEntryIds.add(entryId);
            lines.add(new OrderLineInput(entryId, quantity));
        }
        return lines;
    }

    private static Set<Id> parseSelectedSchemeIds(Object selectedSchemePayload) {
        Set<Id> selectedSchemeIds = new Set<Id>();
        if (selectedSchemePayload == null) {
            return selectedSchemeIds;
        }
        if (!(selectedSchemePayload instanceof List<Object>)) {
            throw new RequestException('Selected schemes must be provided as a list.');
        }
        List<Object> rawIds = (List<Object>) selectedSchemePayload;
        if (rawIds.size() > MAX_ORDER_LINES) {
            throw new RequestException('Select no more than one scheme for each order line.');
        }
        for (Object rawId : rawIds) {
            Id schemeProductId = parseOptionalId(rawId);
            if (schemeProductId == null
                || schemeProductId.getSObjectType() != Scheme_Product__c.SObjectType) {
                throw new RequestException('Each selected scheme must be valid.');
            }
            if (selectedSchemeIds.contains(schemeProductId)) {
                throw new RequestException('A scheme may only be selected once.');
            }
            selectedSchemeIds.add(schemeProductId);
        }
        return selectedSchemeIds;
    }

    private static Map<Id, List<Scheme_Product__c>> selectSchemes(
        Set<Id> selectedSchemeIds,
        Map<Id, List<Scheme_Product__c>> availableSchemesByProduct
    ) {
        Map<Id, List<Scheme_Product__c>> selectedSchemesByProduct =
            new Map<Id, List<Scheme_Product__c>>();
        if (selectedSchemeIds.isEmpty()) {
            return selectedSchemesByProduct;
        }

        Set<Id> matchedSchemeIds = new Set<Id>();
        for (List<Scheme_Product__c> productSchemes : availableSchemesByProduct.values()) {
            for (Scheme_Product__c scheme : productSchemes) {
                if (!selectedSchemeIds.contains(scheme.Id)) {
                    continue;
                }
                if (selectedSchemesByProduct.containsKey(scheme.Product__c)) {
                    throw new RequestException(
                        'Select only one scheme for each product in the order.'
                    );
                }
                selectedSchemesByProduct.put(
                    scheme.Product__c,
                    new List<Scheme_Product__c>{ scheme }
                );
                matchedSchemeIds.add(scheme.Id);
            }
        }
        if (matchedSchemeIds.size() != selectedSchemeIds.size()) {
            throw new ConflictException(
                'One or more selected schemes are no longer active or do not apply to this order.'
            );
        }
        return selectedSchemesByProduct;
    }

    private static Map<String, Object> productSummary(
        PricebookEntry entry,
        Map<String, Decimal> unitFactors
    ) {
        return new Map<String, Object>{
            'pricebookEntryId' => entry.Id,
            'productId' => entry.Product2Id,
            'name' => entry.Product2.Name,
            'productCode' => entry.Product2.ProductCode,
            'description' => entry.Product2.Description,
            'imageUrl' => entry.Product2.DisplayUrl,
            'unitPrice' => entry.UnitPrice,
            'pricebookName' => entry.Pricebook2.Name,
            'unitOfMeasure' => entry.Unit_of_Measure__c,
            'conversionFactor' => entry.Unit_Conversion_Factor__c,
            'baseUnitOfMeasure' => entry.Product2.QuantityUnitOfMeasure,
            'unitFactors' => unitFactors,
            'taxRate' => entry.Product2.DMS_Tax_Rate__c == null
                ? 0
                : entry.Product2.DMS_Tax_Rate__c
        };
    }

    private static Map<String, Object> schemeSummary(Scheme_Product__c scheme) {
        return new Map<String, Object>{
            'id' => scheme.Id,
            'schemeId' => scheme.Scheme__c,
            'name' => scheme.Scheme__r.Scheme_Name__c,
            'productId' => scheme.Product__c,
            'schemeType' => scheme.Scheme__r.Scheme_Type__c,
            'salesType' => scheme.Scheme__r.Sales_Type__c,
            'minimumQuantity' => scheme.Minimum_Quantity__c,
            'minimumUnit' => scheme.Minimum_Unit__c,
            'freeQuantity' => scheme.Free_Quantity__c,
            'freeUnit' => scheme.Free_Unit__c,
            'discountPercentage' => scheme.Discount_Percentage__c,
            'configuredDiscountAmount' => scheme.Discount_Amount__c,
            'priority' => scheme.Priority__c == null ? 0 : scheme.Priority__c,
            'startDate' => scheme.Scheme__r.Start_Date__c,
            'endDate' => scheme.Scheme__r.End_Date__c
        };
    }

    private static Map<String, Object> orderSummary(Order salesOrder) {
        String salesType = salesTypeFromOrder(salesOrder.Type);
        Boolean secondary = salesType == 'Secondary';
        return new Map<String, Object>{
            'id' => salesOrder.Id,
            'orderNumber' => salesOrder.OrderNumber,
            'salesType' => salesType,
            'status' => salesOrder.Status,
            'orderDate' => salesOrder.EffectiveDate,
            'totalAmount' => salesOrder.TotalAmount,
            'customerId' => secondary ? salesOrder.Outlet__c : salesOrder.AccountId,
            'customerName' => secondary
                ? (salesOrder.Outlet__r == null ? null : salesOrder.Outlet__r.Name)
                : salesOrder.Account.Name,
            'distributorId' => salesOrder.AccountId,
            'distributorName' => salesOrder.Account.Name,
            'salesRepresentativeName' => salesOrder.Owner == null
                ? null
                : salesOrder.Owner.Name,
            'retailerId' => salesOrder.Outlet__c,
            'retailerName' => salesOrder.Outlet__r == null
                ? null
                : salesOrder.Outlet__r.Name,
            'fulfillmentWarehouseId' => salesOrder.DMS_Fulfillment_Warehouse__c,
            'fulfillmentWarehouseName' => salesOrder.DMS_Fulfillment_Warehouse__r == null
                ? null
                : salesOrder.DMS_Fulfillment_Warehouse__r.Name,
            'allocationStatus' => String.isBlank(salesOrder.DMS_Allocation_Status__c)
                ? 'Not Allocated'
                : salesOrder.DMS_Allocation_Status__c,
            'approvalAssigneeName' => salesOrder.DMS_Approver__r == null
                ? null
                : salesOrder.DMS_Approver__r.Name
        };
    }

    private static OrderItem buildOrderItem(
        Id orderId,
        CalculatedLine line,
        Decimal quantity,
        Decimal paidQuantity,
        Decimal freeQuantity,
        Decimal unitPrice,
        Decimal taxAmount
    ) {
        return new OrderItem(
            OrderId = orderId,
            PricebookEntryId = line.entry.Id,
            Quantity = quantity,
            UnitPrice = unitPrice,
            DMS_List_Price__c = line.entry.UnitPrice,
            Paid_Quantity__c = paidQuantity,
            Free_Quantity__c = freeQuantity,
            Unit_of_Measure__c = line.entry.Unit_of_Measure__c,
            Unit_Conversion_Factor__c = line.salesFactor,
            DMS_Tax_Rate__c = line.taxRate,
            DMS_Tax_Amount__c = taxAmount.setScale(2)
        );
    }

    private static Order findOrderByRequestKey(String requestKey) {
        List<Order> orders = [
            SELECT Id, AccountId, Type
            FROM Order
            WHERE DMS_Request_Key__c = :requestKey
            LIMIT 1
        ];
        return orders.isEmpty() ? null : orders[0];
    }

    private static String salesTypeFromOrder(String orderTypeValue) {
        if (orderTypeValue == 'Primary Order') {
            return 'Primary';
        }
        if (orderTypeValue == 'Secondary Order') {
            return 'Secondary';
        }
        return null;
    }

    private static String orderType(String salesType) {
        return salesType == 'Primary' ? 'Primary Order' : 'Secondary Order';
    }

    private static String normalizeSalesType(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        if (value.equalsIgnoreCase('Primary')) {
            return 'Primary';
        }
        if (value.equalsIgnoreCase('Secondary')) {
            return 'Secondary';
        }
        return null;
    }

    private static String normalizeUnit(String unit) {
        return String.isBlank(unit) ? null : unit.trim().toLowerCase();
    }

    private static String getSessionToken() {
        if (RestContext.request == null || RestContext.request.headers == null) {
            return null;
        }
        for (String headerName : RestContext.request.headers.keySet()) {
            if (headerName.equalsIgnoreCase('X-DMS-Session')) {
                String token = RestContext.request.headers.get(headerName);
                return String.isBlank(token) ? null : token.trim();
            }
        }
        return null;
    }

    private static Account findDistributor(String token) {
        if (String.isBlank(token) || token.length() != 64
            || !Pattern.matches('^[a-fA-F0-9]{64}$', token)) {
            return null;
        }
        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
        Datetime currentTime = System.now();
        List<Account> distributors = [
            SELECT Id, Name, Account_Category__c, Active__c, Login_Status__c,
                   DMS_Session_Expires_At__c
            FROM Account
            WHERE DMS_Session_Token_Hash__c = :tokenHash
              AND DMS_Session_Expires_At__c > :currentTime
              AND Account_Category__c LIKE '%Distributor%'
              AND Active__c = 'Yes'
              AND Login_Status__c = 'Active'
            LIMIT 1
        ];
        if (distributors.isEmpty()
            || !distributors[0].Account_Category__c.containsIgnoreCase('Distributor')) {
            return null;
        }
        return distributors[0];
    }

    private static String getParameter(String name) {
        return RestContext.request == null || RestContext.request.params == null
            ? null
            : RestContext.request.params.get(name);
    }

    private static Map<String, Object> readPayload() {
        if (RestContext.request == null || RestContext.request.requestBody == null
            || RestContext.request.requestBody.size() == 0) {
            return null;
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
        } catch (Exception error) {
            return null;
        }
    }

    private static Id parseId(String value) {
        Id parsed = parseOptionalId(value);
        if (parsed == null) {
            throw new RequestException('A valid order ID is required.');
        }
        return parsed;
    }

    private static Id parseOptionalId(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        try {
            return Id.valueOf(String.valueOf(value));
        } catch (Exception error) {
            throw new RequestException('A record ID is invalid.');
        }
    }

    private static Decimal parseDecimal(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception error) {
            throw new RequestException('A numeric order value is invalid.');
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

    private class OrderLineInput {
        Id pricebookEntryId;
        Decimal quantity;

        OrderLineInput(Id entryId, Decimal lineQuantity) {
            pricebookEntryId = entryId;
            quantity = lineQuantity;
        }
    }

    private class CalculatedLine {
        PricebookEntry entry;
        Decimal paidQuantity;
        Decimal freeQuantity;
        Decimal salesFactor;
        Scheme_Product__c scheme;
        Decimal taxRate;
        Decimal paidUnitPrice;
        Decimal netAmount;
        Decimal grossAmount;
        Decimal discountAmount;
        Decimal schemeDiscountAmount;
        Decimal taxAmount;
        Decimal lineTotal;
        Map<String, Object> preview;

        CalculatedLine(
            PricebookEntry pricebookEntry,
            Decimal paid,
            Decimal free,
            Decimal factor,
            Scheme_Product__c selectedScheme,
            Decimal configuredTaxRate,
            Decimal netUnitPrice,
            Decimal paidLineAmount,
            Decimal gross,
            Decimal discount,
            Decimal appliedSchemeDiscount,
            Decimal tax,
            Decimal total
        ) {
            entry = pricebookEntry;
            paidQuantity = paid;
            freeQuantity = free;
            salesFactor = factor;
            scheme = selectedScheme;
            taxRate = configuredTaxRate;
            paidUnitPrice = netUnitPrice;
            netAmount = paidLineAmount;
            grossAmount = gross;
            discountAmount = discount;
            schemeDiscountAmount = appliedSchemeDiscount;
            taxAmount = tax;
            lineTotal = total;
        }
    }

    private class OrderCalculation {
        Id pricebookId;
        Account retailer;
        List<CalculatedLine> lines = new List<CalculatedLine>();
        List<Map<String, Object>> previewLines = new List<Map<String, Object>>();
        Decimal subtotal = 0;
        Decimal discount = 0;
        Decimal netAmount = 0;
        Decimal taxTotal = 0;
        Decimal total = 0;
        Map<String, Object> preview;

        OrderCalculation(Id selectedPricebookId, Account selectedRetailer) {
            pricebookId = selectedPricebookId;
            retailer = selectedRetailer;
        }
    }

    private class StockCheck {
        Map<Id, Decimal> quantitiesByProduct;
        Map<Id, Inventory__c> inventoryByProduct;
        List<Map<String, Object>> lines;
        Boolean canReserve;
    }

    private class StockDemand {
        Map<Id, Decimal> quantitiesByProduct;
        Map<Id, String> productNames;
        Map<Id, String> unitsByProduct;
    }

    private class RequestException extends Exception {}
    private class ConflictException extends Exception {}
    private class ConfigurationException extends Exception {}
    private class ReservationAccessException extends Exception {}
}
