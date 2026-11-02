@RestResource(urlMapping='/dms/v1/inventory')
global without sharing class DMSDistributorInventoryResource {
    private static final Integer RECENT_TRANSACTION_LIMIT = 50;
    private static final Integer RECENT_GRN_LIMIT = 50;

    @HttpGet
    global static void getInventory() {
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
            if (RestContext.request.params.get('view') == 'orderReceipts') {
                writeResponse(response, 200, new Map<String, Object>{
                    'success' => true,
                    'dispatches' => getOrderReceiptDispatches(distributor)
                });
                return;
            }
            AggregateResult inventoryTotals = [
                SELECT COUNT(Id) recordCount, COUNT_DISTINCT(Product__c) productCount,
                       SUM(Available_Quantity__c) availableStock,
                       SUM(Reserved_Quantity__c) reservedStock
                FROM Inventory__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ];
            Integer inventoryRecordCount = (Integer) inventoryTotals.get('recordCount');
            Integer totalProducts = (Integer) inventoryTotals.get('productCount');
            Decimal availableStock = inventoryTotals.get('availableStock') == null
                ? 0
                : (Decimal) inventoryTotals.get('availableStock');
            Decimal reservedStock = inventoryTotals.get('reservedStock') == null
                ? 0
                : (Decimal) inventoryTotals.get('reservedStock');
            AggregateResult lowStockResult = [
                SELECT COUNT(Id) lowStockCount
                FROM Inventory__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                  AND Stock_Status__c = 'Low Stock'
            ];

            List<Inventory__c> inventoryRecords = [
                SELECT Id, Name, Warehouse__c, Warehouse__r.Name,
                       Warehouse__r.Warehouse_Code__c, Warehouse__r.Warehouse_Status__c,
                       Product__c, Product__r.Name, Product__r.ProductCode,
                       Product__r.Barcode__c,
                       Product__r.Category__c, Product__r.Family,
                       Available_Quantity__c, Reserved_Quantity__c,
                       Minimum_Stock_Level__c, Stock_Status__c
                FROM Inventory__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                ORDER BY Product__r.Name, Warehouse__r.Name
                LIMIT 2000
            ];
            List<Map<String, Object>> stock = new List<Map<String, Object>>();

            for (Inventory__c inventoryRecord : inventoryRecords) {
                Decimal available = inventoryRecord.Available_Quantity__c == null
                    ? 0
                    : inventoryRecord.Available_Quantity__c;
                Decimal reserved = inventoryRecord.Reserved_Quantity__c == null
                    ? 0
                    : inventoryRecord.Reserved_Quantity__c;

                stock.add(new Map<String, Object>{
                    'id' => inventoryRecord.Id,
                    'productId' => inventoryRecord.Product__c,
                    'productName' => inventoryRecord.Product__r == null
                        ? null
                        : inventoryRecord.Product__r.Name,
                    'productCode' => inventoryRecord.Product__r == null
                        ? null
                        : inventoryRecord.Product__r.ProductCode,
                    'barcode' => inventoryRecord.Product__r == null
                        ? null
                        : inventoryRecord.Product__r.Barcode__c,
                    'category' => inventoryRecord.Product__r == null
                        ? null
                        : inventoryRecord.Product__r.Category__c,
                    'warehouseId' => inventoryRecord.Warehouse__c,
                    'warehouseName' => inventoryRecord.Warehouse__r == null
                        ? null
                        : inventoryRecord.Warehouse__r.Name,
                    'warehouseCode' => inventoryRecord.Warehouse__r == null
                        ? null
                        : inventoryRecord.Warehouse__r.Warehouse_Code__c,
                    'warehouseStatus' => inventoryRecord.Warehouse__r == null
                        ? null
                        : inventoryRecord.Warehouse__r.Warehouse_Status__c,
                    'availableQuantity' => available,
                    'reservedQuantity' => reserved,
                    'onHandQuantity' => available + reserved,
                    'minimumStockLevel' => inventoryRecord.Minimum_Stock_Level__c,
                    'stockStatus' => inventoryRecord.Stock_Status__c
                });
            }

            List<Map<String, Object>> warehouses = new List<Map<String, Object>>();
            for (Warehouse__c warehouse : [
                SELECT Id, Name, Warehouse_Code__c, Warehouse_Address__c,
                       City__c, State__c, PIN_Code__c, Warehouse_Status__c,
                       Warehouse_Type__c
                FROM Warehouse__c
                WHERE Distributor__c = :distributor.Id
                  AND Warehouse_Type__c = 'Distributor Warehouse'
                ORDER BY Name
                LIMIT 2000
            ]) {
                warehouses.add(new Map<String, Object>{
                    'id' => warehouse.Id,
                    'name' => warehouse.Name,
                    'code' => warehouse.Warehouse_Code__c,
                    'type' => warehouse.Warehouse_Type__c,
                    'address' => warehouse.Warehouse_Address__c,
                    'city' => warehouse.City__c,
                    'state' => warehouse.State__c,
                    'postalCode' => warehouse.PIN_Code__c,
                    'status' => warehouse.Warehouse_Status__c
                });
            }
            List<Map<String, Object>> products = new List<Map<String, Object>>();
            for (Product2 product : [
                SELECT Id, Name, ProductCode, Barcode__c, QuantityUnitOfMeasure
                FROM Product2
                WHERE IsActive = true AND SFA_Product__c = true
                ORDER BY Name
                LIMIT 2000
            ]) {
                products.add(new Map<String, Object>{
                    'id' => product.Id,
                    'name' => product.Name,
                    'code' => product.ProductCode,
                    'barcode' => product.Barcode__c,
                    'unitOfMeasure' => product.QuantityUnitOfMeasure
                });
            }

            List<Map<String, Object>> batches = new List<Map<String, Object>>();
            Date today = Date.today();
            Date expiryWindowEnd = today.addDays(30);
            AggregateResult expiredBatchesResult = [
                SELECT COUNT(Id) expiredBatchCount
                FROM Product_Batch__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                  AND Expiry_Date__c < :today
            ];
            AggregateResult expiringBatchesResult = [
                SELECT COUNT(Id) expiringBatchCount
                FROM Product_Batch__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                  AND Expiry_Date__c >= :today
                  AND Expiry_Date__c <= :expiryWindowEnd
            ];
            for (Product_Batch__c batch : [
                SELECT Id, Name, Product__c, Product__r.Name,
                       Warehouse__c, Warehouse__r.Name,
                       Manufacturing_Date__c, Expiry_Date__c, Batch_Quantity__c
                FROM Product_Batch__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                ORDER BY Expiry_Date__c ASC, Name
                LIMIT 2000
            ]) {
                String expiryStatus = 'No expiry date';
                if (batch.Expiry_Date__c != null && batch.Expiry_Date__c < today) {
                    expiryStatus = 'Expired';
                } else if (batch.Expiry_Date__c != null
                    && batch.Expiry_Date__c <= expiryWindowEnd) {
                    expiryStatus = 'Expiring soon';
                }
                batches.add(new Map<String, Object>{
                    'id' => batch.Id,
                    'batchNumber' => batch.Name,
                    'productId' => batch.Product__c,
                    'productName' => batch.Product__r == null ? null : batch.Product__r.Name,
                    'warehouseId' => batch.Warehouse__c,
                    'warehouseName' => batch.Warehouse__r == null ? null : batch.Warehouse__r.Name,
                    'manufacturingDate' => batch.Manufacturing_Date__c,
                    'expiryDate' => batch.Expiry_Date__c,
                    'batchQuantity' => batch.Batch_Quantity__c,
                    'expiryStatus' => expiryStatus
                });
            }

            List<Map<String, Object>> transactions = new List<Map<String, Object>>();
            Decimal receivedToday = 0;
            Decimal soldToday = 0;
            Datetime startOfToday = Datetime.newInstance(today, Time.newInstance(0, 0, 0, 0));
            for (AggregateResult transactionTotal : [
                SELECT Transaction_Type__c transactionType, SUM(Quantity__c) quantityTotal
                FROM Inventory_Transaction__c
                WHERE Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
                  AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                  AND Transaction_Date__c >= :startOfToday
                GROUP BY Transaction_Type__c
            ]) {
                if ((String) transactionTotal.get('transactionType') == 'Primary Order Receipt') {
                    receivedToday = (Decimal) transactionTotal.get('quantityTotal');
                } else if ((String) transactionTotal.get('transactionType') == 'Secondary Order Sale') {
                    soldToday = (Decimal) transactionTotal.get('quantityTotal');
                }
            }

            for (Inventory_Transaction__c stockMovement : [
                SELECT Id, Name, Inventory__c, Inventory__r.Product__r.Name,
                       Inventory__r.Warehouse__r.Name, Transaction_Type__c,
                       Quantity__c, Transaction_Date__c, Reference_Number__c,
                       Transaction_Description__c
                FROM Inventory_Transaction__c
                WHERE Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
                  AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
                ORDER BY Transaction_Date__c DESC
                LIMIT :RECENT_TRANSACTION_LIMIT
            ]) {
                Decimal quantity = stockMovement.Quantity__c == null
                    ? 0
                    : stockMovement.Quantity__c;
                transactions.add(new Map<String, Object>{
                    'id' => stockMovement.Id,
                    'number' => stockMovement.Name,
                    'productName' => stockMovement.Inventory__r == null
                        || stockMovement.Inventory__r.Product__r == null
                        ? null
                        : stockMovement.Inventory__r.Product__r.Name,
                    'warehouseName' => stockMovement.Inventory__r == null
                        || stockMovement.Inventory__r.Warehouse__r == null
                        ? null
                        : stockMovement.Inventory__r.Warehouse__r.Name,
                    'type' => stockMovement.Transaction_Type__c,
                    'quantity' => quantity,
                    'date' => stockMovement.Transaction_Date__c,
                    'referenceNumber' => stockMovement.Reference_Number__c,
                    'description' => stockMovement.Transaction_Description__c
                });
            }

            List<Map<String, Object>> recentGrns = new List<Map<String, Object>>();
            Map<Id, Map<String, Object>> grnSummaryById =
                new Map<Id, Map<String, Object>>();
            for (Goods_Receipt_Note__c grn : [
                SELECT Id, Name, Order__c, Order__r.OrderNumber,
                       Warehouse__c, Warehouse__r.Name, GRN_Date__c,
                       Expected_Quantity__c, Received_Quantity__c,
                       Damaged_Quantity__c, Accepted_Quantity__c, GRN_Status__c,
                       DMS_Dispatch__c, DMS_Dispatch__r.Name, Distributor__r.Name
                FROM Goods_Receipt_Note__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY GRN_Date__c DESC, CreatedDate DESC
                LIMIT :RECENT_GRN_LIMIT
            ]) {
                Map<String, Object> summary = new Map<String, Object>{
                    'id' => grn.Id,
                    'number' => grn.Name,
                    'orderNumber' => grn.Order__r == null ? null : grn.Order__r.OrderNumber,
                    'dispatchId' => grn.DMS_Dispatch__c,
                    'dispatchNumber' => grn.DMS_Dispatch__r == null
                        ? null
                        : grn.DMS_Dispatch__r.Name,
                    'distributorName' => grn.Distributor__r == null
                        ? null
                        : grn.Distributor__r.Name,
                    'warehouseName' => grn.Warehouse__r == null ? null : grn.Warehouse__r.Name,
                    'date' => grn.GRN_Date__c,
                    'expectedQuantity' => grn.Expected_Quantity__c,
                    'receivedQuantity' => grn.Received_Quantity__c,
                    'damagedQuantity' => grn.Damaged_Quantity__c,
                    'acceptedQuantity' => grn.Accepted_Quantity__c,
                    'status' => grn.GRN_Status__c,
                    'lines' => new List<Map<String, Object>>()
                };
                recentGrns.add(summary);
                grnSummaryById.put(grn.Id, summary);
            }
            for (Goods_Receipt_Line_Item__c line : [
                SELECT Id, Goods_Receipt_Note__c, DMS_Dispatch_Line__c,
                       DMS_Dispatch_Line__r.Product_Name_Snapshot__c,
                       DMS_Dispatch_Line__r.Quantity__c,
                       DMS_Dispatch_Line__r.Quantity_Delivered__c,
                       DMS_Dispatch_Line__r.Quantity_Short__c,
                       DMS_Dispatch_Line__r.Quantity_Damaged__c,
                       DMS_Dispatch_Line__r.Unit_of_Measure__c,
                       Order_Line_Item__c, Order_Line_Item__r.Paid_Quantity__c,
                       Order_Line_Item__r.Free_Quantity__c,
                       Order_Line_Item__r.Unit_of_Measure__c,
                       Product__c, Product__r.Name, Expected_Quantity__c,
                       Received_Quantity__c, Accepted_Quantity__c, Damaged_Quantity__c
                FROM Goods_Receipt_Line_Item__c
                WHERE Goods_Receipt_Note__c IN :grnSummaryById.keySet()
                ORDER BY CreatedDate, Id
            ]) {
                Map<String, Object> grnSummary = grnSummaryById.get(
                    line.Goods_Receipt_Note__c
                );
                List<Map<String, Object>> lines =
                    (List<Map<String, Object>>) grnSummary.get('lines');
                String productName = line.Product__r == null
                    ? null
                    : line.Product__r.Name;
                if (String.isBlank(productName)
                    && line.DMS_Dispatch_Line__r != null) {
                    productName = line.DMS_Dispatch_Line__r.Product_Name_Snapshot__c;
                }
                if (String.isBlank(productName)
                    && line.Order_Line_Item__r != null
                    && line.Order_Line_Item__r.Product2 != null) {
                    productName = line.Order_Line_Item__r.Product2.Name;
                }
                Decimal paidQuantity = line.Order_Line_Item__r == null
                    ? null
                    : line.Order_Line_Item__r.Paid_Quantity__c;
                Decimal freeQuantity = line.Order_Line_Item__r == null
                    ? null
                    : line.Order_Line_Item__r.Free_Quantity__c;
                lines.add(new Map<String, Object>{
                    'id' => line.Id,
                    'dispatchLineId' => line.DMS_Dispatch_Line__c,
                    'orderLineId' => line.Order_Line_Item__c,
                    'productId' => line.Product__c,
                    'productName' => productName,
                    'lineType' => getReceiptLineType(paidQuantity, freeQuantity),
                    'paidQuantity' => paidQuantity,
                    'freeQuantity' => freeQuantity,
                    'quantityDispatched' => line.DMS_Dispatch_Line__r == null
                        ? null
                        : line.DMS_Dispatch_Line__r.Quantity__c,
                    'quantityReceived' => line.Received_Quantity__c,
                    'quantityAccepted' => line.Accepted_Quantity__c,
                    'quantityDamaged' => line.Damaged_Quantity__c,
                    'quantityShort' => line.DMS_Dispatch_Line__r == null
                        ? null
                        : line.DMS_Dispatch_Line__r.Quantity_Short__c,
                    'unitOfMeasure' => line.DMS_Dispatch_Line__r == null
                        ? (line.Order_Line_Item__r == null
                            ? null
                            : line.Order_Line_Item__r.Unit_of_Measure__c)
                        : line.DMS_Dispatch_Line__r.Unit_of_Measure__c
                });
            }

            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'summary' => new Map<String, Object>{
                    'totalProducts' => totalProducts,
                    'totalStockOnHand' => availableStock + reservedStock,
                    'availableStock' => availableStock,
                    'reservedStock' => reservedStock,
                    'stockReceivedToday' => receivedToday,
                    'stockSoldToday' => soldToday,
                    'lowStockProducts' => lowStockResult.get('lowStockCount'),
                    'expiringSoonBatches' => expiringBatchesResult.get('expiringBatchCount'),
                    'expiredBatches' => expiredBatchesResult.get('expiredBatchCount'),
                    'warehouseCount' => warehouses.size()
                },
                'warehouses' => warehouses,
                'warehouseStatuses' => activePicklistValues(
                    Schema.sObjectType.Warehouse__c.fields.Warehouse_Status__c
                ),
                'products' => products,
                'stock' => stock,
                'batches' => batches,
                'transactions' => transactions,
                'recentGrns' => recentGrns,
                'capacity' => new Map<String, Object>{
                    'totalInventoryRecords' => inventoryRecordCount,
                    'stockRecordLimit' => 2000,
                    'batchRecordLimit' => 2000,
                    'transactionLimit' => RECENT_TRANSACTION_LIMIT,
                    'grnLimit' => RECENT_GRN_LIMIT
                }
            });
        } catch (InventoryRequestException error) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (InventoryConflictException error) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (Exception error) {
            System.debug(LoggingLevel.ERROR,
                'DMS inventory data could not be loaded: ' + error.getTypeName());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'Inventory data could not be loaded. Please try again.'
            });
        }
    }

    private static List<Map<String, Object>> getOrderReceiptDispatches(Account distributor) {
        Id orderId = parseIdValue(
            RestContext.request.params.get('orderId'),
            Order.SObjectType
        );
        List<Order> matchingOrders = [
            SELECT Id
            FROM Order
            WHERE Id = :orderId
              AND AccountId = :distributor.Id
              AND Type = 'Primary Order'
              AND Status = 'Activated'
            LIMIT 1
        ];
        if (matchingOrders.isEmpty()) {
            throw new InventoryConflictException(
                'The selected primary order is not available for receiving.'
            );
        }
        List<DMS_Dispatch__c> dispatchRecords = [
            SELECT Id, Name, Status__c, Delivery_Status__c, Dispatch_Date__c
            FROM DMS_Dispatch__c
            WHERE Order__c = :orderId
              AND Distributor__c = :distributor.Id
              AND Status__c IN ('Dispatched', 'Partially Delivered')
            ORDER BY Dispatch_Date__c DESC, CreatedDate DESC
        ];
        Set<Id> dispatchIds = new Set<Id>();
        for (DMS_Dispatch__c dispatch : dispatchRecords) dispatchIds.add(dispatch.Id);
        if (dispatchIds.isEmpty()) return new List<Map<String, Object>>();

        Map<String, Decimal> receivedByDispatchOrderLine = new Map<String, Decimal>();
        for (AggregateResult receiptTotal : [
            SELECT Goods_Receipt_Note__r.DMS_Dispatch__c dispatchId,
                   Order_Line_Item__c orderLineId,
                   SUM(Received_Quantity__c) receivedQuantity
            FROM Goods_Receipt_Line_Item__c
            WHERE Goods_Receipt_Note__r.DMS_Dispatch__c IN :dispatchIds
              AND Goods_Receipt_Note__r.Distributor__c = :distributor.Id
              AND Goods_Receipt_Note__r.GRN_Status__c = 'Approved'
            GROUP BY Goods_Receipt_Note__r.DMS_Dispatch__c, Order_Line_Item__c
        ]) {
            String receiptKey = String.valueOf(receiptTotal.get('dispatchId')) + '|' +
                String.valueOf(receiptTotal.get('orderLineId'));
            receivedByDispatchOrderLine.put(
                receiptKey,
                (Decimal) receiptTotal.get('receivedQuantity')
            );
        }

        Map<Id, List<Map<String, Object>>> linesByDispatch =
            new Map<Id, List<Map<String, Object>>>();
        Map<Id, Decimal> quantityByDispatch = new Map<Id, Decimal>();
        List<OrderItem> orderItems = [
            SELECT Id, Product2Id, Product2.Name, Product2.IsActive,
                   Product2.SFA_Product__c, Product2.Batch_Tracked__c, Quantity,
                   Paid_Quantity__c, Free_Quantity__c, Unit_of_Measure__c
            FROM OrderItem
            WHERE OrderId = :orderId
        ];
        Map<Id, OrderItem> orderItemsById = new Map<Id, OrderItem>(orderItems);
        Map<Id, List<OrderItem>> orderItemsByProduct = new Map<Id, List<OrderItem>>();
        for (OrderItem orderItem : orderItems) {
            if (!orderItemsByProduct.containsKey(orderItem.Product2Id)) {
                orderItemsByProduct.put(orderItem.Product2Id, new List<OrderItem>());
            }
            orderItemsByProduct.get(orderItem.Product2Id).add(orderItem);
        }
        for (DMS_Dispatch_Line__c line : [
            SELECT Id, Dispatch__c, Order_Line_Item__c, Product__c,
                   Product__r.Name, Product__r.IsActive, Product__r.SFA_Product__c,
                   Product__r.Batch_Tracked__c, Product_Name_Snapshot__c,
                   Quantity__c, Quantity_Delivered__c,
                   Quantity_Short__c, Quantity_Damaged__c, Unit_of_Measure__c,
                   Order_Line_Item__r.Product2Id,
                   Order_Line_Item__r.Product2.Name,
                   Order_Line_Item__r.Paid_Quantity__c,
                   Order_Line_Item__r.Free_Quantity__c,
                   Order_Line_Item__r.Quantity,
                   Order_Line_Item__r.Unit_of_Measure__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c IN :dispatchIds
            ORDER BY CreatedDate, Id
        ]) {
            OrderItem orderLine;
            if (line.Order_Line_Item__c != null && line.Order_Line_Item__r != null) {
                orderLine = orderItemsById.get(line.Order_Line_Item__c);
            } else {
                List<OrderItem> matchingOrderLines = orderItemsByProduct.get(line.Product__c);
                if (matchingOrderLines != null && matchingOrderLines.size() == 1) {
                    orderLine = matchingOrderLines[0];
                }
            }
            Decimal dispatchedQuantity = line.Quantity__c;
            if ((dispatchedQuantity == null || dispatchedQuantity <= 0)
                && orderLine != null) {
                dispatchedQuantity = orderLine.Quantity;
            }
            if (line.Product__c == null || line.Product__r == null
                || !line.Product__r.IsActive || line.Product__r.SFA_Product__c != true
                || String.isBlank(line.Unit_of_Measure__c)
                || orderLine == null
                || orderLine.Product2Id != line.Product__c
                || String.isBlank(orderLine.Unit_of_Measure__c)
                || !line.Unit_of_Measure__c.trim().equalsIgnoreCase(
                    orderLine.Unit_of_Measure__c.trim()
                )
                || dispatchedQuantity == null || dispatchedQuantity <= 0) {
                throw new InventoryConflictException(
                    'A dispatched line must match one active primary order line with a valid quantity and unit.'
                );
            }
            String receiptKey = String.valueOf(line.Dispatch__c) + '|' +
                String.valueOf(orderLine.Id);
            Decimal previouslyReceived =
                receivedByDispatchOrderLine.containsKey(receiptKey)
                ? receivedByDispatchOrderLine.get(receiptKey)
                : 0;
            if (previouslyReceived > dispatchedQuantity) {
                throw new InventoryConflictException(
                    'Approved receipts exceed a dispatched line quantity. Reconcile the receipt records before continuing.'
                );
            }
            if (!linesByDispatch.containsKey(line.Dispatch__c)) {
                linesByDispatch.put(line.Dispatch__c, new List<Map<String, Object>>());
                quantityByDispatch.put(line.Dispatch__c, 0);
            }
            Decimal remaining = dispatchedQuantity - previouslyReceived;
            quantityByDispatch.put(
                line.Dispatch__c,
                quantityByDispatch.get(line.Dispatch__c) + remaining
            );
            Decimal paidQuantity = orderLine.Paid_Quantity__c;
            Decimal freeQuantity = orderLine.Free_Quantity__c;
            linesByDispatch.get(line.Dispatch__c).add(new Map<String, Object>{
                'id' => line.Id,
                'orderLineId' => orderLine.Id,
                'productId' => line.Product__c,
                'productName' => String.isBlank(line.Product_Name_Snapshot__c)
                    ? line.Product__r.Name
                    : line.Product_Name_Snapshot__c,
                'lineType' => getReceiptLineType(paidQuantity, freeQuantity),
                'paidQuantity' => paidQuantity,
                'freeQuantity' => freeQuantity,
                'quantity' => dispatchedQuantity,
                'receivedQuantityToDate' => previouslyReceived,
                'remainingQuantity' => remaining,
                'deliveredQuantity' => line.Quantity_Delivered__c,
                'shortQuantity' => line.Quantity_Short__c,
                'damagedQuantity' => line.Quantity_Damaged__c,
                'unitOfMeasure' => line.Unit_of_Measure__c,
                'batchTracked' => orderLine.Product2.Batch_Tracked__c
            });
        }

        List<Map<String, Object>> dispatches = new List<Map<String, Object>>();
        for (DMS_Dispatch__c dispatch : dispatchRecords) {
            List<Map<String, Object>> lines = linesByDispatch.get(dispatch.Id);
            if (lines == null || lines.isEmpty()) {
                throw new InventoryConflictException(
                    'A dispatched primary order has no dispatch lines and cannot be received.'
                );
            }
            if (quantityByDispatch.get(dispatch.Id) > 0) {
                dispatches.add(new Map<String, Object>{
                    'id' => dispatch.Id,
                    'number' => dispatch.Name,
                    'status' => dispatch.Status__c,
                    'deliveryStatus' => dispatch.Delivery_Status__c,
                    'dispatchDate' => dispatch.Dispatch_Date__c,
                    'lines' => lines
                });
            }
        }
        return dispatches;
    }

    private static String getReceiptLineType(Decimal paidQuantity, Decimal freeQuantity) {
        Boolean hasPaid = paidQuantity != null && paidQuantity > 0;
        Boolean hasFree = freeQuantity != null && freeQuantity > 0;
        if (hasPaid && hasFree) return 'Paid + Free';
        if (hasFree) return 'Free';
        if (hasPaid) return 'Paid';
        return 'Not recorded';
    }

    @HttpPost
    global static void postInventoryAction() {
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

        Savepoint savepoint = Database.setSavepoint();
        try {
            String action = stringValue(payload.get('action'));
            Map<String, Object> result;
            if (action == 'validateReceiptBarcode') {
                result = validateReceiptBarcode(distributor, payload);
            } else if (action == 'createWarehouse') {
                result = createWarehouse(distributor, payload);
            } else if (action == 'updateWarehouse') {
                result = updateWarehouse(distributor, payload);
            } else if (action == 'receiveStock' || action == 'adjustStock') {
                result = recordStockMovement(distributor, payload, action);
            } else if (action == 'recordGoodsReceipt') {
                result = recordGoodsReceipt(distributor, payload);
            } else if (action == 'transferStock') {
                result = transferStock(distributor, payload);
            } else {
                throw new InventoryRequestException('The requested inventory action is not supported.');
            }
            result.put('success', true);
            writeResponse(response, 200, result);
        } catch (InventoryRequestException error) {
            Database.rollback(savepoint);
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (InventoryConflictException error) {
            Database.rollback(savepoint);
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (InventoryAccessException error) {
            Database.rollback(savepoint);
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (InventoryConfigurationException error) {
            Database.rollback(savepoint);
            writeResponse(response, 503, new Map<String, Object>{
                'success' => false,
                'message' => error.getMessage()
            });
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR,
                'DMS inventory action failed: ' + error.getTypeName());
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The inventory change could not be completed. Please try again.'
            });
        }
    }

    private static Map<String, Object> validateReceiptBarcode(
        Account distributor,
        Map<String, Object> payload
    ) {
        if (String.isBlank(stringValue(payload.get('orderId')))
            || String.isBlank(stringValue(payload.get('dispatchId')))) {
            throw new InventoryRequestException(
                'A valid primary order and dispatched shipment are required.'
            );
        }
        Id orderId = parseIdValue(payload.get('orderId'), Order.SObjectType);
        Id dispatchId = parseIdValue(payload.get('dispatchId'), DMS_Dispatch__c.SObjectType);
        String barcode = stringValue(payload.get('barcode'));
        Decimal proposedQuantity = decimalValue(payload.get('proposedQuantity'), 'Scan quantity');
        if (orderId == null || dispatchId == null || String.isBlank(barcode)
            || barcode.length() > 50 || proposedQuantity == null || proposedQuantity <= 0
            || proposedQuantity != proposedQuantity.setScale(0, RoundingMode.DOWN)) {
            throw new InventoryRequestException(
                'A valid order, dispatch, barcode, and whole-unit scan quantity are required.'
            );
        }

        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Order__c, Status__c, Distributor__c,
                   Order__r.AccountId, Order__r.Type, Order__r.Status
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
              AND Order__c = :orderId
              AND Distributor__c = :distributor.Id
            LIMIT 1
        ];
        if (dispatches.isEmpty() || dispatches[0].Order__r == null
            || dispatches[0].Order__r.AccountId != distributor.Id
            || dispatches[0].Order__r.Type != 'Primary Order'
            || dispatches[0].Order__r.Status != 'Activated'
            || !new Set<String>{ 'Dispatched', 'Partially Delivered' }
                .contains(dispatches[0].Status__c)) {
            throw new InventoryConflictException(
                'The selected shipment is not eligible for receipt.'
            );
        }

        List<Product2> products = [
            SELECT Id, Name, IsActive, SFA_Product__c, QuantityUnitOfMeasure
            FROM Product2
            WHERE Barcode__c = :barcode
            LIMIT 2
        ];
        if (products.isEmpty()) {
            throw new InventoryConflictException('No active product matches this barcode.');
        }
        if (products.size() > 1 || !products[0].IsActive
            || products[0].SFA_Product__c != true) {
            throw new InventoryConflictException(
                'This barcode does not identify one active DMS product.'
            );
        }

        List<DMS_Dispatch_Line__c> lines = [
            SELECT Id, Product__c, Quantity__c, Unit_of_Measure__c,
                   Order_Line_Item__c, Order_Line_Item__r.Unit_of_Measure__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatchId AND Product__c = :products[0].Id
        ];
        if (lines.isEmpty()) {
            throw new InventoryConflictException(
                products[0].Name + ' is not part of the selected dispatched shipment.'
            );
        }
        if (lines.size() > 1) {
            throw new InventoryConflictException(
                'This product has multiple shipment lines. Verify the correct line manually.'
            );
        }
        DMS_Dispatch_Line__c dispatchLine = lines[0];
        List<OrderItem> matchingOrderLines = [
            SELECT Id, Product2Id, Quantity, Unit_of_Measure__c
            FROM OrderItem
            WHERE OrderId = :orderId AND Product2Id = :products[0].Id
        ];
        if (dispatchLine.Order_Line_Item__c != null) {
            matchingOrderLines = [
                SELECT Id, Product2Id, Quantity, Unit_of_Measure__c
                FROM OrderItem
                WHERE Id = :dispatchLine.Order_Line_Item__c
                  AND OrderId = :orderId
            ];
        }
        if (matchingOrderLines.size() != 1) {
            throw new InventoryConflictException(
                'The barcode cannot be matched to one primary order line on this shipment.'
            );
        }
        OrderItem orderLine = matchingOrderLines[0];
        Decimal dispatchedQuantity = dispatchLine.Quantity__c;
        if (dispatchedQuantity == null || dispatchedQuantity <= 0) {
            dispatchedQuantity = orderLine.Quantity;
        }
        if (dispatchedQuantity == null || dispatchedQuantity <= 0) {
            throw new InventoryConflictException(
                'The selected shipment line is missing a valid quantity.'
            );
        }
        String productUnit = products[0].QuantityUnitOfMeasure == null
            ? ''
            : products[0].QuantityUnitOfMeasure.trim().toLowerCase();
        String dispatchUnit = dispatchLine.Unit_of_Measure__c == null
            ? ''
            : dispatchLine.Unit_of_Measure__c.trim().toLowerCase();
        String orderUnit = orderLine.Unit_of_Measure__c == null
            ? ''
            : orderLine.Unit_of_Measure__c.trim().toLowerCase();
        if (String.isBlank(productUnit) || productUnit != dispatchUnit
            || String.isBlank(orderUnit) || orderUnit != dispatchUnit) {
            throw new InventoryConflictException(
                'The barcode packaging unit does not match the shipment line unit. Enter the receipt quantity manually.'
            );
        }
        AggregateResult receiptSummary = [
            SELECT SUM(Received_Quantity__c) receivedQuantity
            FROM Goods_Receipt_Line_Item__c
            WHERE Order_Line_Item__c = :orderLine.Id
              AND Goods_Receipt_Note__r.DMS_Dispatch__c = :dispatchId
              AND Goods_Receipt_Note__r.Distributor__c = :distributor.Id
              AND Goods_Receipt_Note__r.GRN_Status__c = 'Approved'
        ];
        Decimal previouslyReceived = (Decimal) receiptSummary.get('receivedQuantity');
        if (previouslyReceived == null) previouslyReceived = 0;
        Decimal remaining = Math.max(0, dispatchedQuantity - previouslyReceived);
        if (proposedQuantity > remaining) {
            throw new InventoryConflictException(
                'The scanned quantity exceeds the shipment quantity remaining to receive.'
            );
        }
        return new Map<String, Object>{
            'productId' => products[0].Id,
            'dispatchLineId' => dispatchLine.Id,
            'remainingQuantity' => remaining,
            'inventoryChanged' => false
        };
    }

    private static Map<String, Object> recordGoodsReceipt(
        Account distributor,
        Map<String, Object> payload
    ) {
        requirePermission(
            Schema.sObjectType.Goods_Receipt_Note__c.isCreateable()
            && Schema.sObjectType.Goods_Receipt_Line_Item__c.isCreateable()
            && Schema.sObjectType.Inventory__c.isCreateable()
            && Schema.sObjectType.Inventory__c.isUpdateable()
            && Schema.sObjectType.Inventory_Transaction__c.isCreateable()
        );
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Distributor__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Order__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.DMS_Dispatch__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Warehouse__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.GRN_Date__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Expected_Quantity__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Received_Quantity__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Damaged_Quantity__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.GRN_Status__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Supplier_Delivery_Number__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Remarks__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Request_Key__c,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Request_Fingerprint__c
        }, true);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Goods_Receipt_Note__c,
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Order_Line_Item__c,
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Product__c,
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Expected_Quantity__c,
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Received_Quantity__c,
            Schema.sObjectType.Goods_Receipt_Line_Item__c.fields.Damaged_Quantity__c
        }, true);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Warehouse__c,
            Schema.sObjectType.Inventory__c.fields.Product__c,
            Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Minimum_Stock_Level__c
        }, true);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Available_Quantity__c
        }, false);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory_Transaction__c.fields.Inventory__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Goods_Receipt_Note__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Quantity__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Date__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c
        }, true);
        String requestKey = stringValue(payload.get('requestKey'));
        if (String.isBlank(requestKey)) {
            throw new InventoryRequestException('A unique request key is required.');
        }
        String scopedRequestKey = EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(String.valueOf(distributor.Id) + '|' + requestKey)
            )
        );
        validateLength(
            requestKey,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Request_Key__c.getLength(),
            'Request key'
        );
        Id orderId = parseIdValue(payload.get('orderId'), Order.SObjectType);
        Id dispatchId = parseIdValue(
            payload.get('dispatchId'),
            DMS_Dispatch__c.SObjectType
        );
        Id warehouseId = parseIdValue(payload.get('warehouseId'), Warehouse__c.SObjectType);
        String dateValue = stringValue(payload.get('receiptDate'));
        Date receiptDate;
        try {
            receiptDate = String.isBlank(dateValue) ? Date.today() : Date.valueOf(dateValue);
        } catch (Exception error) {
            throw new InventoryRequestException('Receipt date must be a valid date.');
        }
        String supplierDeliveryNumber = stringValue(payload.get('supplierDeliveryNumber'));
        String remarks = stringValue(payload.get('remarks'));
        validateLength(
            supplierDeliveryNumber,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Supplier_Delivery_Number__c.getLength(),
            'Supplier delivery number'
        );
        validateLength(
            remarks,
            Schema.sObjectType.Goods_Receipt_Note__c.fields.Remarks__c.getLength(),
            'Receipt remarks'
        );

        Object rawLines = payload.get('lines');
        if (!(rawLines instanceof List<Object>)) {
            throw new InventoryRequestException('At least one received order line is required.');
        }
        List<Object> linePayloads = (List<Object>) rawLines;
        if (linePayloads.isEmpty()) {
            throw new InventoryRequestException('At least one received order line is required.');
        }
        List<GoodsReceiptLineInput> receiptLines = new List<GoodsReceiptLineInput>();
        Set<Id> dispatchLineIds = new Set<Id>();
        Set<Id> orderLineIds = new Set<Id>();
        List<String> fingerprintLines = new List<String>();
        Boolean hasReceivedQuantity = false;
        for (Object rawLine : linePayloads) {
            if (!(rawLine instanceof Map<String, Object>)) {
                throw new InventoryRequestException('Each receipt line must be a valid object.');
            }
            Map<String, Object> lineMap = (Map<String, Object>) rawLine;
            GoodsReceiptLineInput receiptLine = new GoodsReceiptLineInput();
            String dispatchLineIdValue = stringValue(lineMap.get('dispatchLineId'));
            receiptLine.linkDispatchLine = !String.isBlank(dispatchLineIdValue);
            receiptLine.dispatchLineId = receiptLine.linkDispatchLine
                ? parseIdValue(dispatchLineIdValue, DMS_Dispatch_Line__c.SObjectType)
                : null;
            String orderLineIdValue = stringValue(lineMap.get('orderLineId'));
            receiptLine.orderLineId = String.isBlank(orderLineIdValue)
                ? null
                : parseIdValue(orderLineIdValue, OrderItem.SObjectType);
            receiptLine.receivedQuantity = decimalValue(
                lineMap.get('receivedQuantity'),
                'Received quantity'
            );
            receiptLine.damagedQuantity = decimalValue(
                lineMap.get('damagedQuantity'),
                'Damaged quantity'
            );
            receiptLine.batchAllocations = parseReceiptBatchAllocations(
                lineMap.get('batches')
            );
            if (receiptLine.receivedQuantity < 0
                || receiptLine.damagedQuantity < 0
                || receiptLine.damagedQuantity > receiptLine.receivedQuantity) {
                throw new InventoryRequestException(
                    'Received quantities must be nonnegative and damaged quantity cannot exceed received quantity.'
                );
            }
            if (receiptLine.receivedQuantity > 0) hasReceivedQuantity = true;
            if (receiptLine.orderLineId == null) {
                throw new InventoryRequestException(
                    'Each receipt line must identify a primary order line item.'
                );
            }
            if (orderLineIds.contains(receiptLine.orderLineId)) {
                throw new InventoryRequestException(
                    'A primary order line can only appear once per receipt.'
                );
            }
            orderLineIds.add(receiptLine.orderLineId);
            if (receiptLine.dispatchLineId != null) {
                dispatchLineIds.add(receiptLine.dispatchLineId);
            }
            fingerprintLines.add(
                String.valueOf(receiptLine.dispatchLineId) + ':' +
                String.valueOf(receiptLine.orderLineId) + ':' +
                String.valueOf(receiptLine.receivedQuantity) + ':' +
                String.valueOf(receiptLine.damagedQuantity) + ':' +
                receiptBatchFingerprint(receiptLine.batchAllocations)
            );
            receiptLines.add(receiptLine);
        }
        if (!hasReceivedQuantity) {
            throw new InventoryRequestException('Enter a received quantity greater than zero.');
        }
        fingerprintLines.sort();
        String fingerprintValue = String.valueOf(orderId) + '|' +
            String.valueOf(dispatchId) + '|' +
            String.valueOf(warehouseId) + '|' + String.valueOf(receiptDate) + '|' +
            String.valueOf(supplierDeliveryNumber) + '|' + String.valueOf(remarks) + '|' +
            String.join(fingerprintLines, '|');
        String requestFingerprint = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(fingerprintValue))
        );

        lockDistributor(distributor.Id);
        List<Goods_Receipt_Note__c> existingReceipts = [
            SELECT Id, Name, Request_Fingerprint__c, Received_Quantity__c,
                   Damaged_Quantity__c, Accepted_Quantity__c
            FROM Goods_Receipt_Note__c
            WHERE Request_Key__c = :scopedRequestKey
            LIMIT 1
            FOR UPDATE
        ];
        if (!existingReceipts.isEmpty()) {
            Goods_Receipt_Note__c existingReceipt = existingReceipts[0];
            if (existingReceipt.Request_Fingerprint__c != requestFingerprint) {
                throw new InventoryConflictException(
                    'This request key has already been used for different receipt details.'
                );
            }
            return goodsReceiptResponse(existingReceipt, true);
        }

        List<Order> orders = [
            SELECT Id, OrderNumber, Type, Status, AccountId, DMS_Fulfillment_Warehouse__c
            FROM Order
            WHERE Id = :orderId AND AccountId = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (orders.isEmpty() || orders[0].Type != 'Primary Order'
            || orders[0].Status != 'Activated') {
            throw new InventoryConflictException(
                'Goods receipts can only be recorded against an activated primary order belonging to this distributor.'
            );
        }
        Order salesOrder = orders[0];

        List<DMS_Dispatch__c> matchingDispatches = [
            SELECT Id, Name, Status__c, Delivery_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
              AND Order__c = :salesOrder.Id
              AND Distributor__c = :distributor.Id
            LIMIT 1
            FOR UPDATE
        ];
        if (matchingDispatches.isEmpty()) {
            throw new InventoryConflictException(
                'Select a dispatched primary shipment belonging to this order and distributor.'
            );
        }
        DMS_Dispatch__c dispatch = matchingDispatches[0];
        if (dispatch.Status__c != 'Dispatched'
            && dispatch.Status__c != 'Partially Delivered') {
            throw new InventoryConflictException(
                'Select a dispatched primary shipment belonging to this order and distributor.'
            );
        }

        List<Warehouse__c> warehouses = [
            SELECT Id, Name, Warehouse_Type__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouseId
              AND Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
            LIMIT 1
            FOR UPDATE
        ];
        if (warehouses.isEmpty() || warehouses[0].Warehouse_Status__c != 'Active') {
            throw new InventoryConflictException(
                'Select an active warehouse that belongs to this distributor.'
            );
        }
        if (salesOrder.DMS_Fulfillment_Warehouse__c != null
            && salesOrder.DMS_Fulfillment_Warehouse__c != warehouseId) {
            throw new InventoryConflictException(
                'Receive this order into its allocated fulfillment warehouse.'
            );
        }

        List<DMS_Dispatch_Line__c> dispatchLines = [
            SELECT Id, Order_Line_Item__c, Product__c, Quantity__c,
                   Quantity_Delivered__c, Quantity_Short__c, Quantity_Damaged__c,
                   Unit_of_Measure__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
            FOR UPDATE
        ];
        Map<Id, DMS_Dispatch_Line__c> dispatchLinesById =
            new Map<Id, DMS_Dispatch_Line__c>(dispatchLines);
        if (dispatchLines.isEmpty()
            || !dispatchLinesById.keySet().containsAll(dispatchLineIds)) {
            throw new InventoryConflictException(
                'A receipt line references a dispatch line outside the selected shipment.'
            );
        }

        Map<Id, OrderItem> orderItemsById = new Map<Id, OrderItem>([
            SELECT Id, Product2Id, Product2.Name, Product2.IsActive,
                   Product2.Batch_Tracked__c,
                   Product2.SFA_Product__c, Quantity, Paid_Quantity__c,
                   Free_Quantity__c, Unit_of_Measure__c
            FROM OrderItem
            WHERE Id IN :orderLineIds AND OrderId = :orderId
        ]);
        if (orderItemsById.size() != orderLineIds.size()) {
            throw new InventoryConflictException(
                'A receipt line must reference a primary order line belonging to the selected order.'
            );
        }

        Map<Id, List<DMS_Dispatch_Line__c>> dispatchLinesByProduct =
            new Map<Id, List<DMS_Dispatch_Line__c>>();
        for (DMS_Dispatch_Line__c dispatchLine : dispatchLines) {
            if (!dispatchLinesByProduct.containsKey(dispatchLine.Product__c)) {
                dispatchLinesByProduct.put(
                    dispatchLine.Product__c,
                    new List<DMS_Dispatch_Line__c>()
                );
            }
            dispatchLinesByProduct.get(dispatchLine.Product__c).add(dispatchLine);
        }
        Set<Id> resolvedDispatchLineIds = new Set<Id>();
        Map<Id, Id> orderLineByDispatchLineId = new Map<Id, Id>();
        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            OrderItem orderLine = orderItemsById.get(receiptLine.orderLineId);
            DMS_Dispatch_Line__c dispatchLine;
            if (receiptLine.dispatchLineId != null) {
                dispatchLine = dispatchLinesById.get(receiptLine.dispatchLineId);
                if (dispatchLine.Order_Line_Item__c != null
                    && dispatchLine.Order_Line_Item__c != orderLine.Id) {
                    throw new InventoryConflictException(
                        'The receipt order line does not match its dispatched line.'
                    );
                }
                if (dispatchLine.Product__c != orderLine.Product2Id) {
                    throw new InventoryConflictException(
                        'The receipt order line product does not match its dispatched line.'
                    );
                }
            } else {
                List<DMS_Dispatch_Line__c> candidates =
                    dispatchLinesByProduct.get(orderLine.Product2Id);
                if (candidates != null) {
                    if (candidates.size() == 1) {
                        dispatchLine = candidates[0];
                    } else {
                        for (DMS_Dispatch_Line__c candidate : candidates) {
                            if (candidate.Order_Line_Item__c == orderLine.Id) {
                                if (dispatchLine != null) {
                                    dispatchLine = null;
                                    break;
                                }
                                dispatchLine = candidate;
                            }
                        }
                    }
                }
                if (dispatchLine == null) {
                    throw new InventoryConflictException(
                        'The primary order line does not identify one matching line on the selected shipment.'
                    );
                }
            }
            if (resolvedDispatchLineIds.contains(dispatchLine.Id)) {
                throw new InventoryConflictException(
                    'A shipment line can only appear once per receipt.'
                );
            }
            resolvedDispatchLineIds.add(dispatchLine.Id);
            orderLineByDispatchLineId.put(dispatchLine.Id, orderLine.Id);
            receiptLine.dispatchLineId = dispatchLine.Id;
        }
        if (resolvedDispatchLineIds.size() != dispatchLines.size()) {
            throw new InventoryConflictException(
                'Include each line from the selected shipment in the GRN.'
            );
        }

        Map<Id, Decimal> previouslyReceivedByOrderLine = new Map<Id, Decimal>();
        Map<Id, Decimal> previouslyDamagedByOrderLine = new Map<Id, Decimal>();
        for (AggregateResult previousReceipt : [
            SELECT Order_Line_Item__c orderLineId,
                   SUM(Received_Quantity__c) receivedQuantity,
                   SUM(Damaged_Quantity__c) damagedQuantity
            FROM Goods_Receipt_Line_Item__c
            WHERE Order_Line_Item__c IN :orderLineIds
              AND Goods_Receipt_Note__r.DMS_Dispatch__c = :dispatch.Id
              AND Goods_Receipt_Note__r.Distributor__c = :distributor.Id
              AND Goods_Receipt_Note__r.GRN_Status__c = 'Approved'
            GROUP BY Order_Line_Item__c
        ]) {
            Id orderLineId = (Id) previousReceipt.get('orderLineId');
            previouslyReceivedByOrderLine.put(
                orderLineId,
                (Decimal) previousReceipt.get('receivedQuantity')
            );
            previouslyDamagedByOrderLine.put(
                orderLineId,
                (Decimal) previousReceipt.get('damagedQuantity')
            );
        }

        Decimal expectedTotal = 0;
        Decimal receivedTotal = 0;
        Decimal damagedTotal = 0;
        Set<Id> productIds = new Set<Id>();
        Set<Id> dispatchedProductIds = new Set<Id>();
        for (DMS_Dispatch_Line__c dispatchLine : dispatchLines) {
            if (dispatchLine.Product__c != null) {
                dispatchedProductIds.add(dispatchLine.Product__c);
            }
        }
        Map<Id, Product2> productsById = new Map<Id, Product2>([
            SELECT Id, Name, IsActive, SFA_Product__c, Batch_Tracked__c
            FROM Product2
            WHERE Id IN :dispatchedProductIds
        ]);
        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            DMS_Dispatch_Line__c dispatchLine =
                dispatchLinesById.get(receiptLine.dispatchLineId);
            OrderItem orderLine = orderItemsById.get(receiptLine.orderLineId);
            Decimal dispatchedQuantity = dispatchLine == null
                ? null
                : dispatchLine.Quantity__c;
            if ((dispatchedQuantity == null || dispatchedQuantity <= 0)
                && orderLine != null) {
                dispatchedQuantity = orderLine.Quantity;
            }
            Product2 product = dispatchLine == null
                ? null
                : productsById.get(dispatchLine.Product__c);
            if (dispatchLine == null || product == null
                || !product.IsActive || product.SFA_Product__c != true
                || String.isBlank(dispatchLine.Unit_of_Measure__c)
                || (orderLine != null
                    && ((dispatchLine.Order_Line_Item__c != null
                            && dispatchLine.Order_Line_Item__c != orderLine.Id)
                        || orderLine.Product2Id != product.Id
                        || !orderLine.Product2.IsActive
                        || orderLine.Product2.SFA_Product__c != true
                        || String.isBlank(orderLine.Unit_of_Measure__c)
                        || !dispatchLine.Unit_of_Measure__c.trim().equalsIgnoreCase(
                            orderLine.Unit_of_Measure__c.trim()
                        )))
                || dispatchedQuantity == null || dispatchedQuantity <= 0) {
                throw new InventoryConflictException(
                    'A dispatched line does not have a consistent active product, quantity, or unit of measure.'
                );
            }
            receiptLine.productId = product.Id;
            validateReceiptBatchAllocations(
                receiptLine,
                product.Batch_Tracked__c
            );
            Decimal previouslyReceived = previouslyReceivedByOrderLine.containsKey(
                orderLine.Id
            )
                ? previouslyReceivedByOrderLine.get(orderLine.Id)
                : 0;
            Decimal previouslyDamaged = previouslyDamagedByOrderLine.containsKey(
                orderLine.Id
            )
                ? previouslyDamagedByOrderLine.get(orderLine.Id)
                : 0;
            if (previouslyReceived > dispatchedQuantity
                || receiptLine.receivedQuantity > dispatchedQuantity - previouslyReceived) {
                throw new InventoryConflictException(
                    'Received quantity exceeds the remaining dispatched quantity for ' +
                    product.Name + '.'
                );
            }
            Decimal previousShort = previouslyReceived > 0
                ? dispatchedQuantity - previouslyReceived
                : 0;
            if (previouslyReceived > 0
                && ((dispatchLine.Quantity_Delivered__c == null
                        ? 0
                        : dispatchLine.Quantity_Delivered__c) != previouslyReceived
                    || (dispatchLine.Quantity_Damaged__c == null
                        ? 0
                        : dispatchLine.Quantity_Damaged__c) != previouslyDamaged
                    || (dispatchLine.Quantity_Short__c == null
                        ? 0
                        : dispatchLine.Quantity_Short__c) != previousShort)) {
                throw new InventoryConflictException(
                    'The dispatch line has receipt quantities that do not match its approved GRNs. Reconcile the existing delivery data before posting another GRN.'
                );
            }
            Decimal acceptedQuantity =
                receiptLine.receivedQuantity - receiptLine.damagedQuantity;
            receiptLine.productName = product.Name;
            receiptLine.expectedQuantity = dispatchedQuantity;
            receiptLine.acceptedQuantity = acceptedQuantity;
            expectedTotal += dispatchedQuantity;
            receivedTotal += receiptLine.receivedQuantity;
            damagedTotal += receiptLine.damagedQuantity;
            if (receiptLine.receivedQuantity > 0) productIds.add(product.Id);
        }

        if (!isActivePicklistValue(
            Schema.sObjectType.Goods_Receipt_Note__c.fields.GRN_Status__c,
            'Approved'
        ) || !isActivePicklistValue(
            Schema.sObjectType.DMS_Dispatch__c.fields.Delivery_Status__c,
            'Partially Delivered'
        ) || !isActivePicklistValue(
            Schema.sObjectType.DMS_Dispatch__c.fields.Delivery_Status__c,
            'Delivered'
        ) || !isActivePicklistValue(
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            'Primary Order Receipt'
        ) || !isActivePicklistValue(
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            'Damaged Stock'
        )) {
            throw new InventoryConfigurationException(
                'Salesforce must enable the Approved GRN, Partially Delivered and Delivered dispatch delivery statuses, and Primary Order Receipt and Damaged Stock transaction types before goods can be received.'
            );
        }

        Goods_Receipt_Note__c goodsReceipt = new Goods_Receipt_Note__c(
            Distributor__c = distributor.Id,
            Order__c = salesOrder.Id,
            DMS_Dispatch__c = dispatch.Id,
            Warehouse__c = warehouseId,
            GRN_Date__c = receiptDate,
            Expected_Quantity__c = expectedTotal,
            Received_Quantity__c = receivedTotal,
            Damaged_Quantity__c = damagedTotal,
            GRN_Status__c = 'Approved',
            Supplier_Delivery_Number__c = supplierDeliveryNumber,
            Remarks__c = remarks,
            Request_Key__c = scopedRequestKey,
            Request_Fingerprint__c = requestFingerprint
        );
        insert goodsReceipt;

        saveReceiptBatches(receiptLines, warehouseId);
        List<Goods_Receipt_Line_Item__c> receiptLineRecords =
            new List<Goods_Receipt_Line_Item__c>();
        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            if (receiptLine.batchAllocations.isEmpty()) {
                receiptLineRecords.add(new Goods_Receipt_Line_Item__c(
                    Goods_Receipt_Note__c = goodsReceipt.Id,
                    DMS_Dispatch_Line__c = receiptLine.linkDispatchLine
                        ? receiptLine.dispatchLineId
                        : null,
                    Order_Line_Item__c = receiptLine.orderLineId,
                    Product__c = receiptLine.productId,
                    Expected_Quantity__c = receiptLine.expectedQuantity,
                    Received_Quantity__c = receiptLine.receivedQuantity,
                    Damaged_Quantity__c = receiptLine.damagedQuantity
                ));
            } else {
                Boolean firstAllocation = true;
                for (GoodsReceiptBatchInput allocation : receiptLine.batchAllocations) {
                    receiptLineRecords.add(new Goods_Receipt_Line_Item__c(
                        Goods_Receipt_Note__c = goodsReceipt.Id,
                        DMS_Dispatch_Line__c = receiptLine.linkDispatchLine
                            ? receiptLine.dispatchLineId
                            : null,
                        Order_Line_Item__c = receiptLine.orderLineId,
                        Product__c = receiptLine.productId,
                        Product_Batch__c = allocation.productBatchId,
                        Expected_Quantity__c = firstAllocation
                            ? receiptLine.expectedQuantity
                            : 0,
                        Received_Quantity__c = allocation.receivedQuantity,
                        Damaged_Quantity__c = allocation.damagedQuantity
                    ));
                    firstAllocation = false;
                }
            }
        }
        insert receiptLineRecords;
        Map<Id, Decimal> receivedByOrderLine = new Map<Id, Decimal>();
        Map<Id, Decimal> damagedByOrderLine = new Map<Id, Decimal>();
        for (AggregateResult receiptTotal : [
            SELECT Order_Line_Item__c orderLineId,
                   SUM(Received_Quantity__c) receivedQuantity,
                   SUM(Damaged_Quantity__c) damagedQuantity
            FROM Goods_Receipt_Line_Item__c
            WHERE Order_Line_Item__c IN :orderLineIds
              AND Goods_Receipt_Note__r.DMS_Dispatch__c = :dispatch.Id
              AND Goods_Receipt_Note__r.Distributor__c = :distributor.Id
              AND Goods_Receipt_Note__r.GRN_Status__c = 'Approved'
            GROUP BY Order_Line_Item__c
        ]) {
            Id orderLineId = (Id) receiptTotal.get('orderLineId');
            receivedByOrderLine.put(
                orderLineId,
                (Decimal) receiptTotal.get('receivedQuantity')
            );
            damagedByOrderLine.put(
                orderLineId,
                (Decimal) receiptTotal.get('damagedQuantity')
            );
        }
        Boolean allDelivered = true;
        for (DMS_Dispatch_Line__c dispatchLine : dispatchLines) {
            Id orderLineId = dispatchLine.Order_Line_Item__c == null
                ? orderLineByDispatchLineId.get(dispatchLine.Id)
                : dispatchLine.Order_Line_Item__c;
            OrderItem orderLine = orderItemsById.get(orderLineId);
            Decimal quantityReceived = receivedByOrderLine.containsKey(orderLineId)
                ? receivedByOrderLine.get(orderLineId)
                : 0;
            Decimal quantityDamaged = damagedByOrderLine.containsKey(orderLineId)
                ? damagedByOrderLine.get(orderLineId)
                : 0;
            Decimal dispatchedQuantity = dispatchLine.Quantity__c;
            if ((dispatchedQuantity == null || dispatchedQuantity <= 0)
                && orderLine != null) {
                dispatchedQuantity = orderLine.Quantity;
            }
            if (dispatchedQuantity == null || quantityReceived > dispatchedQuantity) {
                throw new InventoryConflictException(
                    'Approved receipts exceed a dispatched line quantity.'
                );
            }
            dispatchLine.Quantity_Delivered__c = quantityReceived;
            dispatchLine.Quantity_Damaged__c = quantityDamaged;
            dispatchLine.Quantity_Short__c = dispatchedQuantity - quantityReceived;
            if (quantityReceived < dispatchedQuantity) allDelivered = false;
        }
        dispatch.Delivery_Status__c = allDelivered ? 'Delivered' : 'Partially Delivered';
        try {
            update dispatchLines;
            update dispatch;
        } catch (DmlException error) {
            throw new InventoryConflictException(
                'The dispatch receipt summary could not be synchronized: ' +
                error.getDmlMessage(0)
            );
        }

        String goodsReceiptNumber = [
            SELECT Name
            FROM Goods_Receipt_Note__c
            WHERE Id = :goodsReceipt.Id
            LIMIT 1
        ].Name;

        Map<Id, Inventory__c> balancesByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c balance : [
            SELECT Id, Product__c, Available_Quantity__c, Reserved_Quantity__c,
                   Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId AND Product__c IN :productIds
            FOR UPDATE
        ]) {
            if (balancesByProduct.containsKey(balance.Product__c)) {
                throw new InventoryConflictException(
                    'Duplicate inventory balances exist for a received product. Resolve them before posting this GRN.'
                );
            }
            balancesByProduct.put(balance.Product__c, balance);
        }
        List<Inventory__c> newBalances = new List<Inventory__c>();
        for (Id productId : productIds) {
            if (!balancesByProduct.containsKey(productId)) {
                Inventory__c newBalance = new Inventory__c(
                    Warehouse__c = warehouseId,
                    Product__c = productId,
                    Available_Quantity__c = 0,
                    Reserved_Quantity__c = 0,
                    Minimum_Stock_Level__c = 0
                );
                newBalances.add(newBalance);
                balancesByProduct.put(productId, newBalance);
            }
        }
        if (!newBalances.isEmpty()) insert newBalances;

        List<Inventory__c> balancesToUpdate = new List<Inventory__c>();
        Map<Id, Inventory__c> balancesToUpdateById = new Map<Id, Inventory__c>();
        List<Inventory_Transaction__c> transactions = new List<Inventory_Transaction__c>();
        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            if (receiptLine.receivedQuantity == 0) continue;
            Inventory__c balance = balancesByProduct.get(receiptLine.productId);
            Decimal available = balance.Available_Quantity__c == null
                ? 0
                : balance.Available_Quantity__c;
            Decimal acceptedQuantity = receiptLine.acceptedQuantity;
            Decimal damagedQuantity = receiptLine.damagedQuantity;
            balance.Available_Quantity__c = available + acceptedQuantity;
            if (receiptLine.batchAllocations.isEmpty()) {
                addReceiptInventoryTransactions(
                    transactions,
                    balance.Id,
                    goodsReceipt.Id,
                    goodsReceiptNumber,
                    salesOrder.OrderNumber,
                    receiptDate,
                    receiptLine,
                    null,
                    acceptedQuantity,
                    damagedQuantity
                );
            } else {
                for (GoodsReceiptBatchInput allocation : receiptLine.batchAllocations) {
                    addReceiptInventoryTransactions(
                        transactions,
                        balance.Id,
                        goodsReceipt.Id,
                        goodsReceiptNumber,
                        salesOrder.OrderNumber,
                        receiptDate,
                        receiptLine,
                        allocation.productBatchId,
                        allocation.receivedQuantity - allocation.damagedQuantity,
                        allocation.damagedQuantity
                    );
                }
            }
            balancesToUpdateById.put(balance.Id, balance);
        }
        balancesToUpdate.addAll(balancesToUpdateById.values());
        if (!balancesToUpdate.isEmpty()) update balancesToUpdate;
        if (!transactions.isEmpty()) insert transactions;

        goodsReceipt = [
            SELECT Id, Name, Request_Fingerprint__c, Received_Quantity__c,
                   Damaged_Quantity__c, Accepted_Quantity__c
            FROM Goods_Receipt_Note__c
            WHERE Id = :goodsReceipt.Id
            LIMIT 1
        ];
        return goodsReceiptResponse(goodsReceipt, false);
    }

    private static Map<String, Object> goodsReceiptResponse(
        Goods_Receipt_Note__c goodsReceipt,
        Boolean alreadyProcessed
    ) {
        return new Map<String, Object>{
            'message' => alreadyProcessed
                ? 'This goods receipt was already recorded.'
                : 'Goods receipt recorded and accepted stock posted.',
            'grnId' => goodsReceipt.Id,
            'grnNumber' => goodsReceipt.Name,
            'receivedQuantity' => goodsReceipt.Received_Quantity__c,
            'damagedQuantity' => goodsReceipt.Damaged_Quantity__c,
            'acceptedQuantity' => goodsReceipt.Accepted_Quantity__c,
            'alreadyProcessed' => alreadyProcessed
        };
    }

    private static void saveReceiptBatches(
        List<GoodsReceiptLineInput> receiptLines,
        Id warehouseId
    ) {
        Map<String, GoodsReceiptBatchInput> sampleByKey =
            new Map<String, GoodsReceiptBatchInput>();
        Map<String, Decimal> acceptedByKey = new Map<String, Decimal>();
        Set<Id> productIds = new Set<Id>();
        Set<String> batchNumbers = new Set<String>();
        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            for (GoodsReceiptBatchInput allocation : receiptLine.batchAllocations) {
                String key = getBatchKey(
                    allocation.productId,
                    warehouseId,
                    allocation.batchNumber
                );
                allocation.batchKey = key;
                if (sampleByKey.containsKey(key)) {
                    GoodsReceiptBatchInput existingAllocation = sampleByKey.get(key);
                    if (existingAllocation.manufacturingDate != allocation.manufacturingDate
                        || existingAllocation.expiryDate != allocation.expiryDate) {
                        throw new InventoryConflictException(
                            'The same batch number has conflicting manufacturing or expiry dates in this GRN.'
                        );
                    }
                } else {
                    sampleByKey.put(key, allocation);
                }
                Decimal accepted = allocation.receivedQuantity
                    - allocation.damagedQuantity;
                acceptedByKey.put(
                    key,
                    (acceptedByKey.containsKey(key) ? acceptedByKey.get(key) : 0)
                        + accepted
                );
                productIds.add(allocation.productId);
                batchNumbers.add(allocation.batchNumber);
            }
        }
        if (sampleByKey.isEmpty()) return;

        requirePermission(
            Schema.sObjectType.Product_Batch__c.isCreateable()
            && Schema.sObjectType.Product_Batch__c.isUpdateable()
        );
        List<Schema.DescribeFieldResult> batchFields = new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Product_Batch__c.fields.Name,
            Schema.sObjectType.Product_Batch__c.fields.Product__c,
            Schema.sObjectType.Product_Batch__c.fields.Warehouse__c,
            Schema.sObjectType.Product_Batch__c.fields.Manufacturing_Date__c,
            Schema.sObjectType.Product_Batch__c.fields.Expiry_Date__c,
            Schema.sObjectType.Product_Batch__c.fields.Batch_Quantity__c
        };
        requireFieldPermissions(batchFields, true);
        requireFieldPermissions(batchFields, false);

        Map<String, Product_Batch__c> batchesByKey =
            new Map<String, Product_Batch__c>();
        Set<String> keys = sampleByKey.keySet();
        for (Product_Batch__c batch : [
            SELECT Id, Name, Batch_Key__c, Product__c, Warehouse__c,
                   Manufacturing_Date__c, Expiry_Date__c, Batch_Quantity__c
            FROM Product_Batch__c
            WHERE Batch_Key__c IN :keys
            FOR UPDATE
        ]) {
            batchesByKey.put(batch.Batch_Key__c, batch);
        }

        for (Product_Batch__c legacyBatch : [
            SELECT Id, Name, Batch_Key__c, Product__c, Warehouse__c,
                   Manufacturing_Date__c, Expiry_Date__c, Batch_Quantity__c
            FROM Product_Batch__c
            WHERE Product__c IN :productIds
              AND Warehouse__c = :warehouseId
              AND Name IN :batchNumbers
            FOR UPDATE
        ]) {
            String key = getBatchKey(
                legacyBatch.Product__c,
                warehouseId,
                legacyBatch.Name
            );
            if (batchesByKey.containsKey(key)
                && batchesByKey.get(key).Id != legacyBatch.Id) {
                throw new InventoryConflictException(
                    'Duplicate Product Batch records exist for the same product, warehouse, and batch number. Reconcile them before receiving stock.'
                );
            }
            batchesByKey.put(key, legacyBatch);
        }

        List<Product_Batch__c> batchesToSave = new List<Product_Batch__c>();
        for (String key : sampleByKey.keySet()) {
            GoodsReceiptBatchInput allocation = sampleByKey.get(key);
            Product_Batch__c batch = batchesByKey.get(key);
            if (batch == null) {
                batch = new Product_Batch__c(
                    Name = allocation.batchNumber,
                    Batch_Key__c = key,
                    Product__c = allocation.productId,
                    Warehouse__c = warehouseId,
                    Manufacturing_Date__c = allocation.manufacturingDate,
                    Expiry_Date__c = allocation.expiryDate,
                    Batch_Quantity__c = acceptedByKey.get(key)
                );
            } else {
                if ((batch.Manufacturing_Date__c != null
                        && allocation.manufacturingDate != null
                        && batch.Manufacturing_Date__c != allocation.manufacturingDate)
                    || (batch.Expiry_Date__c != null
                        && batch.Expiry_Date__c != allocation.expiryDate)) {
                    throw new InventoryConflictException(
                        'This product, warehouse, and batch number already exists with different expiry details.'
                    );
                }
                batch.Batch_Key__c = key;
                if (batch.Manufacturing_Date__c == null) {
                    batch.Manufacturing_Date__c = allocation.manufacturingDate;
                }
                if (batch.Expiry_Date__c == null) batch.Expiry_Date__c = allocation.expiryDate;
                Decimal available = batch.Batch_Quantity__c == null
                    ? 0
                    : batch.Batch_Quantity__c;
                batch.Batch_Quantity__c = available + acceptedByKey.get(key);
            }
            batchesByKey.put(key, batch);
            batchesToSave.add(batch);
        }
        upsert batchesToSave Batch_Key__c;

        for (GoodsReceiptLineInput receiptLine : receiptLines) {
            for (GoodsReceiptBatchInput allocation : receiptLine.batchAllocations) {
                allocation.productBatchId = batchesByKey.get(allocation.batchKey).Id;
            }
        }
    }

    private static String getBatchKey(Id productId, Id warehouseId, String batchNumber) {
        String identity = String.valueOf(productId) + '|' +
            String.valueOf(warehouseId) + '|' + batchNumber.trim().toLowerCase();
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(identity))
        );
    }

    private static void addReceiptInventoryTransactions(
        List<Inventory_Transaction__c> transactions,
        Id inventoryId,
        Id goodsReceiptId,
        String goodsReceiptNumber,
        String orderNumber,
        Date receiptDate,
        GoodsReceiptLineInput receiptLine,
        Id productBatchId,
        Decimal acceptedQuantity,
        Decimal damagedQuantity
    ) {
        String batchSuffix = productBatchId == null
            ? ''
            : '-' + String.valueOf(productBatchId);
        Datetime transactionDate = Datetime.newInstance(
            receiptDate,
            Time.newInstance(12, 0, 0, 0)
        );
        String orderLineReference = String.valueOf(
            receiptLine.orderLineId == null
                ? receiptLine.dispatchLineId
                : receiptLine.orderLineId
        );
        if (acceptedQuantity > 0) {
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = inventoryId,
                Goods_Receipt_Note__c = goodsReceiptId,
                Product_Batch__c = productBatchId,
                Transaction_Type__c = 'Primary Order Receipt',
                Quantity__c = acceptedQuantity,
                Transaction_Date__c = transactionDate,
                Reference_Number__c = goodsReceiptNumber + '-' +
                    String.valueOf(receiptLine.dispatchLineId) + '-' +
                    orderLineReference + '-ACCEPTED' + batchSuffix,
                Transaction_Description__c =
                    'Accepted goods from primary order ' + orderNumber
            ));
        }
        if (damagedQuantity > 0) {
            transactions.add(new Inventory_Transaction__c(
                Inventory__c = inventoryId,
                Goods_Receipt_Note__c = goodsReceiptId,
                Product_Batch__c = productBatchId,
                Transaction_Type__c = 'Damaged Stock',
                Quantity__c = damagedQuantity,
                Transaction_Date__c = transactionDate,
                Reference_Number__c = goodsReceiptNumber + '-' +
                    String.valueOf(receiptLine.dispatchLineId) + '-' +
                    orderLineReference + '-DAMAGED' + batchSuffix,
                Transaction_Description__c =
                    'Damaged goods excluded from stock for order ' + orderNumber
            ));
        }
    }

    private static Map<String, Object> createWarehouse(
        Account distributor,
        Map<String, Object> payload
    ) {
        requirePermission(Schema.sObjectType.Warehouse__c.isCreateable());
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Warehouse__c.fields.Name,
            Schema.sObjectType.Warehouse__c.fields.Distributor__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Type__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Status__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Address__c,
            Schema.sObjectType.Warehouse__c.fields.City__c,
            Schema.sObjectType.Warehouse__c.fields.State__c,
            Schema.sObjectType.Warehouse__c.fields.PIN_Code__c
        }, true);
        String name = stringValue(payload.get('name'));
        if (String.isBlank(name)) {
            throw new InventoryRequestException('Warehouse name is required.');
        }
        validateLength(name, Schema.sObjectType.Warehouse__c.fields.Name.getLength(), 'Warehouse name');

        lockDistributor(distributor.Id);
        Warehouse__c warehouse = new Warehouse__c(
            Name = name,
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active',
            Warehouse_Address__c = stringValue(payload.get('address')),
            City__c = stringValue(payload.get('city')),
            State__c = stringValue(payload.get('state')),
            PIN_Code__c = stringValue(payload.get('postalCode'))
        );
        validateWarehouseDetails(warehouse);
        validateWarehouseStatus(warehouse.Warehouse_Status__c);
        insert warehouse;
        warehouse = [
            SELECT Id, Name, Warehouse_Code__c, Warehouse_Type__c, Warehouse_Address__c,
                   City__c, State__c, PIN_Code__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouse.Id
              AND Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
            LIMIT 1
        ];
        return warehouseResponse(warehouse, 'Warehouse created.');
    }

    private static Map<String, Object> updateWarehouse(
        Account distributor,
        Map<String, Object> payload
    ) {
        requirePermission(Schema.sObjectType.Warehouse__c.isUpdateable());
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Warehouse__c.fields.Name,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Type__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Status__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Address__c,
            Schema.sObjectType.Warehouse__c.fields.City__c,
            Schema.sObjectType.Warehouse__c.fields.State__c,
            Schema.sObjectType.Warehouse__c.fields.PIN_Code__c
        }, false);
        Id warehouseId = parseIdValue(payload.get('warehouseId'), Warehouse__c.SObjectType);
        lockDistributor(distributor.Id);
        List<Warehouse__c> matches = [
            SELECT Id, Name, Warehouse_Code__c, Warehouse_Type__c, Warehouse_Address__c, City__c,
                   State__c, PIN_Code__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouseId
              AND Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
            LIMIT 1
            FOR UPDATE
        ];
        if (matches.isEmpty()) {
            throw new InventoryConflictException('The requested warehouse is not available to this distributor.');
        }

        Warehouse__c warehouse = matches[0];
        if (payload.containsKey('name')) {
            String name = stringValue(payload.get('name'));
            if (String.isBlank(name)) {
                throw new InventoryRequestException('Warehouse name is required.');
            }
            warehouse.Name = name;
        }
        validateLength(warehouse.Name, Schema.sObjectType.Warehouse__c.fields.Name.getLength(), 'Warehouse name');

        if (payload.containsKey('address')) warehouse.Warehouse_Address__c = stringValue(payload.get('address'));
        if (payload.containsKey('city')) warehouse.City__c = stringValue(payload.get('city'));
        if (payload.containsKey('state')) warehouse.State__c = stringValue(payload.get('state'));
        if (payload.containsKey('postalCode')) warehouse.PIN_Code__c = stringValue(payload.get('postalCode'));
        if (payload.containsKey('status')) {
            String status = stringValue(payload.get('status'));
            validateWarehouseStatus(status);
            if (warehouse.Warehouse_Status__c == 'Active' && status != 'Active') {
                ensureWarehouseCanBeDeactivated(warehouse.Id);
            }
            warehouse.Warehouse_Status__c = status;
        }
        validateWarehouseDetails(warehouse);
        update warehouse;
        return warehouseResponse(warehouse, 'Warehouse updated.');
    }

    private static Map<String, Object> recordStockMovement(
        Account distributor,
        Map<String, Object> payload,
        String action
    ) {
        requirePermission(
            Schema.sObjectType.Inventory__c.isCreateable()
            && Schema.sObjectType.Inventory__c.isUpdateable()
            && Schema.sObjectType.Inventory_Transaction__c.isCreateable()
        );
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Warehouse__c,
            Schema.sObjectType.Inventory__c.fields.Product__c,
            Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Minimum_Stock_Level__c
        }, false);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory_Transaction__c.fields.Inventory__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Quantity__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Date__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c
        }, true);

        Id warehouseId = parseIdValue(payload.get('warehouseId'), Warehouse__c.SObjectType);
        Id productId = parseIdValue(payload.get('productId'), Product2.SObjectType);
        Decimal quantity = decimalValue(payload.get('quantity'), 'Quantity');
        String reference = stringValue(payload.get('referenceNumber'));
        String reason = stringValue(payload.get('reason'));
        Boolean isAdjustment = action == 'adjustStock';
        String direction = stringValue(payload.get('direction'));
        String transactionType = isAdjustment ? 'Stock Adjustment' : 'Primary Order Receipt';

        if (quantity <= 0) {
            throw new InventoryRequestException('Quantity must be greater than zero.');
        }
        if (String.isBlank(reference)) {
            throw new InventoryRequestException('A unique transaction reference is required.');
        }
        validateLength(
            reference,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c.getLength(),
            'Transaction reference'
        );
        validateLength(
            reason,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c.getLength(),
            'Transaction reason'
        );
        if (!isAdjustment) {
            reason = String.isBlank(reason) ? 'Stock receipt' : reason;
        } else if (String.isNotBlank(direction)) {
            direction = direction.toLowerCase();
        }
        if (isAdjustment && (String.isBlank(reason)
            || (direction != 'increase' && direction != 'decrease'))) {
            throw new InventoryRequestException(
                'Stock adjustments require a reason and an increase or decrease direction.'
            );
        }
        if (!isAdjustment) {
            reason = String.isBlank(reason) ? 'Stock receipt' : reason;
        }
        String transactionDescription = isAdjustment
            ? (direction == 'increase' ? 'Increase: ' : 'Decrease: ') + reason
            : reason;
        validateLength(
            transactionDescription,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c.getLength(),
            'Transaction description'
        );
        if (!isActivePicklistValue(
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            transactionType
        )) {
            throw new InventoryConfigurationException(
                'Salesforce inventory transaction types must include "' + transactionType + '" before this action can be used.'
            );
        }

        List<Warehouse__c> warehouses = [
            SELECT Id, Warehouse_Type__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Id = :warehouseId
              AND Distributor__c = :distributor.Id
              AND Warehouse_Type__c = 'Distributor Warehouse'
            LIMIT 1
            FOR UPDATE
        ];
        if (warehouses.isEmpty()) {
            throw new InventoryConflictException('The selected warehouse is not available to this distributor.');
        }
        if (warehouses[0].Warehouse_Status__c != 'Active') {
            throw new InventoryConflictException('Stock cannot be changed in an inactive warehouse.');
        }

        List<Product2> products = [
            SELECT Id, IsActive, SFA_Product__c
            FROM Product2
            WHERE Id = :productId
            LIMIT 1
        ];
        if (products.isEmpty() || !products[0].IsActive || !products[0].SFA_Product__c) {
            throw new InventoryConflictException('The selected product is missing, inactive, or not part of the DMS catalogue.');
        }

        List<Inventory__c> balances = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c, Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId AND Product__c = :productId
            LIMIT 2
            FOR UPDATE
        ];
        if (balances.size() > 1) {
            throw new InventoryConflictException(
                'Duplicate inventory balances exist for this product and warehouse. Resolve them before posting stock.'
            );
        }
        Inventory__c balance = balances.isEmpty() ? null : balances[0];
        if (isAdjustment && balance == null) {
            throw new InventoryConflictException('An inventory balance is required before stock can be adjusted.');
        }
        if (balance == null
            && UserInfo.getUserType() != 'Guest'
            && !Schema.sObjectType.Inventory__c.isCreateable()) {
            throw new InventoryAccessException('You do not have permission to create an inventory balance.');
        }
        if (balance == null) {
            requireFieldPermissions(new List<Schema.DescribeFieldResult>{
                Schema.sObjectType.Inventory__c.fields.Warehouse__c,
                Schema.sObjectType.Inventory__c.fields.Product__c,
                Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
                Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
                Schema.sObjectType.Inventory__c.fields.Minimum_Stock_Level__c
            }, true);
        }

        if (balance != null) {
            List<Inventory_Transaction__c> duplicateTransactions = [
                SELECT Id, Quantity__c, Transaction_Description__c
                FROM Inventory_Transaction__c
                WHERE Inventory__c = :balance.Id
                  AND Reference_Number__c = :reference
                  AND Transaction_Type__c = :transactionType
                LIMIT 2
            ];
            if (!duplicateTransactions.isEmpty()) {
                if (duplicateTransactions.size() == 1
                    && duplicateTransactions[0].Quantity__c == quantity
                    && duplicateTransactions[0].Transaction_Description__c == transactionDescription) {
                    return new Map<String, Object>{
                        'message' => 'This stock movement was already recorded.',
                        'inventoryId' => balance.Id,
                        'availableQuantity' => balance.Available_Quantity__c,
                        'reservedQuantity' => balance.Reserved_Quantity__c,
                        'alreadyProcessed' => true
                    };
                }
                throw new InventoryConflictException('This transaction reference has already been used for a different stock movement.');
            }
        }

        if (balance == null) {
            balance = new Inventory__c(
                Warehouse__c = warehouseId,
                Product__c = productId,
                Available_Quantity__c = quantity,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 0
            );
        } else {
            Decimal available = balance.Available_Quantity__c == null
                ? 0
                : balance.Available_Quantity__c;
            Decimal reserved = balance.Reserved_Quantity__c == null
                ? 0
                : balance.Reserved_Quantity__c;
            if (isAdjustment && direction == 'decrease' && available < quantity) {
                throw new InventoryConflictException(
                    'The adjustment would reduce available stock below zero or consume stock reserved for orders.'
                );
            }
            balance.Available_Quantity__c = isAdjustment && direction == 'decrease'
                ? available - quantity
                : available + quantity;
            if (reserved < 0 || balance.Available_Quantity__c < 0) {
                throw new InventoryConflictException('The movement would violate inventory balance limits.');
            }
        }
        Inventory_Transaction__c movementRecord = new Inventory_Transaction__c(
            Inventory__c = balance.Id,
            Transaction_Type__c = transactionType,
            Quantity__c = quantity,
            Transaction_Date__c = System.now(),
            Reference_Number__c = reference,
            Transaction_Description__c = transactionDescription
        );
        if (balances.isEmpty()) {
            insert balance;
            movementRecord.Inventory__c = balance.Id;
        } else {
            update balance;
        }
        insert movementRecord;
        return new Map<String, Object>{
            'message' => isAdjustment ? 'Stock adjustment recorded.' : 'Stock receipt recorded.',
            'inventoryId' => balance.Id,
            'availableQuantity' => balance.Available_Quantity__c,
            'reservedQuantity' => balance.Reserved_Quantity__c,
            'alreadyProcessed' => false
        };
    }

    private static Map<String, Object> transferStock(
        Account distributor,
        Map<String, Object> payload
    ) {
        requirePermission(
            Schema.sObjectType.Inventory__c.isCreateable()
            && Schema.sObjectType.Inventory__c.isUpdateable()
            && Schema.sObjectType.Inventory_Transaction__c.isCreateable()
        );
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory__c.fields.Warehouse__c,
            Schema.sObjectType.Inventory__c.fields.Product__c,
            Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
            Schema.sObjectType.Inventory__c.fields.Minimum_Stock_Level__c
        }, false);
        requireFieldPermissions(new List<Schema.DescribeFieldResult>{
            Schema.sObjectType.Inventory_Transaction__c.fields.Inventory__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Quantity__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Date__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c
        }, true);

        Id sourceWarehouseId = parseIdValue(payload.get('sourceWarehouseId'), Warehouse__c.SObjectType);
        Id destinationWarehouseId = parseIdValue(payload.get('destinationWarehouseId'), Warehouse__c.SObjectType);
        Id productId = parseIdValue(payload.get('productId'), Product2.SObjectType);
        Decimal quantity = decimalValue(payload.get('quantity'), 'Quantity');
        String reference = stringValue(payload.get('referenceNumber'));
        String reason = stringValue(payload.get('reason'));
        if (sourceWarehouseId == destinationWarehouseId) {
            throw new InventoryRequestException('Choose two different warehouses for the transfer.');
        }
        if (quantity <= 0 || String.isBlank(reference) || String.isBlank(reason)) {
            throw new InventoryRequestException('Transfer quantity, reference, and reason are required.');
        }
        validateLength(
            reference,
            Schema.sObjectType.Inventory_Transaction__c.fields.Reference_Number__c.getLength(),
            'Transaction reference'
        );
        validateLength(
            reason,
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c.getLength(),
            'Transfer reason'
        );
        String transactionType = 'Stock Transfer';
        if (!isActivePicklistValue(
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Type__c,
            transactionType
        )) {
            throw new InventoryConfigurationException(
                'Salesforce inventory transaction types must include "Stock Transfer" before transfers can be used.'
            );
        }

        List<Id> warehouseIds = new List<Id>{sourceWarehouseId, destinationWarehouseId};
        warehouseIds.sort();
        Map<Id, Warehouse__c> warehousesById = new Map<Id, Warehouse__c>();
        for (Id warehouseId : warehouseIds) {
            List<Warehouse__c> matches = [
                SELECT Id, Name, Warehouse_Type__c, Warehouse_Status__c
                FROM Warehouse__c
                WHERE Id = :warehouseId
                  AND Distributor__c = :distributor.Id
                  AND Warehouse_Type__c = 'Distributor Warehouse'
                LIMIT 1
                FOR UPDATE
            ];
            if (matches.isEmpty()) {
                throw new InventoryConflictException('Both transfer warehouses must belong to your distributor account.');
            }
            if (matches[0].Warehouse_Status__c != 'Active') {
                throw new InventoryConflictException('Both transfer warehouses must be active.');
            }
            warehousesById.put(matches[0].Id, matches[0]);
        }

        List<Product2> products = [
            SELECT Id, IsActive, SFA_Product__c
            FROM Product2
            WHERE Id = :productId
            LIMIT 1
        ];
        if (products.isEmpty() || !products[0].IsActive || !products[0].SFA_Product__c) {
            throw new InventoryConflictException('The selected product is missing, inactive, or not part of the DMS catalogue.');
        }

        List<Inventory__c> balances = [
            SELECT Id, Product__c, Warehouse__c, Available_Quantity__c,
                   Reserved_Quantity__c, Minimum_Stock_Level__c
            FROM Inventory__c
            WHERE Product__c = :productId
              AND Warehouse__c IN :warehouseIds
            LIMIT 3
            FOR UPDATE
        ];
        Map<Id, Inventory__c> balancesByWarehouse = new Map<Id, Inventory__c>();
        for (Inventory__c balance : balances) {
            if (balancesByWarehouse.containsKey(balance.Warehouse__c)) {
                throw new InventoryConflictException(
                    'Duplicate inventory balances exist for this product and warehouse.'
                );
            }
            balancesByWarehouse.put(balance.Warehouse__c, balance);
        }
        Inventory__c sourceBalance = balancesByWarehouse.get(sourceWarehouseId);
        if (sourceBalance == null) {
            throw new InventoryConflictException('The source warehouse has no inventory balance for this product.');
        }
        List<Inventory_Transaction__c> existingTransactions = [
            SELECT Id, Inventory__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = :reference
              AND Transaction_Type__c = :transactionType
              AND Inventory__r.Warehouse__r.Distributor__c = :distributor.Id
              AND Inventory__r.Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
        ];
        if (!existingTransactions.isEmpty()) {
            Boolean sourceRecorded = false;
            Boolean destinationRecorded = false;
            for (Inventory_Transaction__c stockTransaction : existingTransactions) {
                if (stockTransaction.Inventory__c == sourceBalance.Id && stockTransaction.Quantity__c == quantity) {
                    sourceRecorded = true;
                }
                Inventory__c destinationBalance = balancesByWarehouse.get(destinationWarehouseId);
                if (destinationBalance != null
                    && stockTransaction.Inventory__c == destinationBalance.Id
                    && stockTransaction.Quantity__c == quantity) {
                    destinationRecorded = true;
                }
            }
            if (existingTransactions.size() == 2 && sourceRecorded && destinationRecorded) {
                return new Map<String, Object>{
                    'message' => 'This stock transfer was already recorded.',
                    'alreadyProcessed' => true,
                    'sourceWarehouseId' => sourceWarehouseId,
                    'destinationWarehouseId' => destinationWarehouseId
                };
            }
            throw new InventoryConflictException('This transfer reference has already been used.');
        }
        Decimal sourceAvailable = sourceBalance.Available_Quantity__c == null
            ? 0
            : sourceBalance.Available_Quantity__c;
        if (sourceAvailable < quantity) {
            throw new InventoryConflictException('Available source stock is insufficient for this transfer.');
        }

        Inventory__c destinationBalance = balancesByWarehouse.get(destinationWarehouseId);
        if (destinationBalance == null) {
            requireFieldPermissions(new List<Schema.DescribeFieldResult>{
                Schema.sObjectType.Inventory__c.fields.Warehouse__c,
                Schema.sObjectType.Inventory__c.fields.Product__c,
                Schema.sObjectType.Inventory__c.fields.Available_Quantity__c,
                Schema.sObjectType.Inventory__c.fields.Reserved_Quantity__c,
                Schema.sObjectType.Inventory__c.fields.Minimum_Stock_Level__c
            }, true);
            destinationBalance = new Inventory__c(
                Warehouse__c = destinationWarehouseId,
                Product__c = productId,
                Available_Quantity__c = 0,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 0
            );
        }

        sourceBalance.Available_Quantity__c = sourceAvailable - quantity;
        destinationBalance.Available_Quantity__c =
            (destinationBalance.Available_Quantity__c == null ? 0 : destinationBalance.Available_Quantity__c)
            + quantity;
        String sourceDescription = 'Transfer out to '
            + warehousesById.get(destinationWarehouseId).Name + ': ' + reason;
        String destinationDescription = 'Transfer in from '
            + warehousesById.get(sourceWarehouseId).Name + ': ' + reason;
        Integer descriptionLength =
            Schema.sObjectType.Inventory_Transaction__c.fields.Transaction_Description__c.getLength();
        validateLength(sourceDescription, descriptionLength, 'Transfer description');
        validateLength(destinationDescription, descriptionLength, 'Transfer description');

        Savepoint savepoint = Database.setSavepoint();
        try {
            update sourceBalance;
            if (destinationBalance.Id == null) {
                insert destinationBalance;
            } else {
                update destinationBalance;
            }
            insert new List<Inventory_Transaction__c>{
                new Inventory_Transaction__c(
                    Inventory__c = sourceBalance.Id,
                    Transaction_Type__c = transactionType,
                    Quantity__c = quantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = reference,
                    Transaction_Description__c = sourceDescription
                ),
                new Inventory_Transaction__c(
                    Inventory__c = destinationBalance.Id,
                    Transaction_Type__c = transactionType,
                    Quantity__c = quantity,
                    Transaction_Date__c = System.now(),
                    Reference_Number__c = reference,
                    Transaction_Description__c = destinationDescription
                )
            };
            return new Map<String, Object>{
                'message' => 'Stock transfer completed.',
                'alreadyProcessed' => false,
                'sourceWarehouseId' => sourceWarehouseId,
                'destinationWarehouseId' => destinationWarehouseId,
                'quantity' => quantity
            };
        } catch (Exception error) {
            Database.rollback(savepoint);
            System.debug(LoggingLevel.ERROR, 'DMS stock transfer failed: ' + error.getTypeName());
            throw new InventoryConflictException('The transfer was not completed. Retry after verifying the stock balances.');
        }
    }

    private static void ensureWarehouseCanBeDeactivated(Id warehouseId) {
        if (![SELECT Id FROM Inventory__c
              WHERE Warehouse__c = :warehouseId
                AND (Available_Quantity__c > 0 OR Reserved_Quantity__c > 0)
              LIMIT 1].isEmpty()) {
            throw new InventoryConflictException(
                'This warehouse cannot be deactivated while it contains available or reserved stock.'
            );
        }
        if (![SELECT Id FROM DMS_Invoice__c
              WHERE Warehouse__c = :warehouseId AND Status__c = 'Draft'
              LIMIT 1].isEmpty()) {
            throw new InventoryConflictException(
                'This warehouse cannot be deactivated while draft invoices are pending.'
            );
        }
        if (![SELECT Id FROM Goods_Receipt_Note__c
              WHERE Warehouse__c = :warehouseId AND GRN_Status__c = 'Submitted'
              LIMIT 1].isEmpty()) {
            throw new InventoryConflictException(
                'This warehouse cannot be deactivated while submitted goods receipts are pending.'
            );
        }
    }

    private static void lockDistributor(Id distributorId) {
        List<Account> accounts = [
            SELECT Id FROM Account WHERE Id = :distributorId LIMIT 1 FOR UPDATE
        ];
        if (accounts.isEmpty()) {
            throw new InventoryConflictException('The authenticated distributor is no longer available.');
        }
    }

    private static void validateWarehouseStatus(String status) {
        if (String.isBlank(status)
            || !isActivePicklistValue(
                Schema.sObjectType.Warehouse__c.fields.Warehouse_Status__c,
                status
            )) {
            throw new InventoryRequestException('Select a valid warehouse status.');
        }
    }

    private static void validateWarehouseDetails(Warehouse__c warehouse) {
        validateLength(
            warehouse.Warehouse_Address__c,
            Schema.sObjectType.Warehouse__c.fields.Warehouse_Address__c.getLength(),
            'Warehouse address'
        );
        validateLength(
            warehouse.City__c,
            Schema.sObjectType.Warehouse__c.fields.City__c.getLength(),
            'Warehouse city'
        );
        validateLength(
            warehouse.State__c,
            Schema.sObjectType.Warehouse__c.fields.State__c.getLength(),
            'Warehouse state'
        );
        validateLength(
            warehouse.PIN_Code__c,
            Schema.sObjectType.Warehouse__c.fields.PIN_Code__c.getLength(),
            'Warehouse postal code'
        );
    }

    private static Boolean isActivePicklistValue(
        Schema.DescribeFieldResult description,
        String value
    ) {
        if (description.getType() != Schema.DisplayType.Picklist) return true;
        for (Schema.PicklistEntry option : description.getPicklistValues()) {
            if (option.isActive() && option.getValue() == value) return true;
        }
        return false;
    }

    private static List<String> activePicklistValues(Schema.DescribeFieldResult description) {
        List<String> values = new List<String>();
        if (description.getType() != Schema.DisplayType.Picklist) return values;
        for (Schema.PicklistEntry option : description.getPicklistValues()) {
            if (option.isActive()) values.add(option.getValue());
        }
        return values;
    }

    private static Map<String, Object> warehouseResponse(Warehouse__c warehouse, String message) {
        return new Map<String, Object>{
            'message' => message,
            'warehouse' => new Map<String, Object>{
                'id' => warehouse.Id,
                'name' => warehouse.Name,
                'code' => warehouse.Warehouse_Code__c,
                'type' => warehouse.Warehouse_Type__c,
                'address' => warehouse.Warehouse_Address__c,
                'city' => warehouse.City__c,
                'state' => warehouse.State__c,
                'postalCode' => warehouse.PIN_Code__c,
                'status' => warehouse.Warehouse_Status__c
            }
        };
    }

    private static void requirePermission(Boolean allowed) {
        // Guest Experience Cloud calls are authorized by the validated DMS token and distributor scope.
        if (UserInfo.getUserType() == 'Guest') return;
        if (!allowed) {
            throw new InventoryAccessException('You do not have permission to perform this inventory operation.');
        }
    }

    private static void validateLength(String value, Integer maxLength, String label) {
        if (value != null && value.length() > maxLength) {
            throw new InventoryRequestException(label + ' is too long.');
        }
    }

    private static Id parseIdValue(Object rawValue, Schema.SObjectType expectedType) {
        String value = stringValue(rawValue);
        if (String.isBlank(value)) {
            throw new InventoryRequestException('A valid record ID is required.');
        }
        Id recordId;
        try {
            recordId = Id.valueOf(value);
        } catch (Exception error) {
            throw new InventoryRequestException('A valid record ID is required.');
        }
        if (recordId.getSObjectType() != expectedType) {
            throw new InventoryRequestException('The record ID has an unexpected type.');
        }
        return recordId;
    }

    private static Decimal decimalValue(Object rawValue, String label) {
        if (rawValue == null) {
            throw new InventoryRequestException(label + ' is required.');
        }
        try {
            return Decimal.valueOf(String.valueOf(rawValue));
        } catch (Exception error) {
            throw new InventoryRequestException(label + ' must be a valid number.');
        }
    }

    private static String stringValue(Object rawValue) {
        return rawValue == null ? null : String.valueOf(rawValue).trim();
    }

    private static Map<String, Object> readPayload() {
        if (RestContext.request == null || RestContext.request.requestBody == null) return null;
        try {
            Object raw = JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : null;
        } catch (Exception error) {
            return null;
        }
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
            SELECT Id
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

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> body
    ) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static void requireFieldPermissions(
        List<Schema.DescribeFieldResult> fields,
        Boolean creating
    ) {
        if (UserInfo.getUserType() == 'Guest') return;
        for (Schema.DescribeFieldResult description : fields) {
            if ((creating && !description.isCreateable())
                || (!creating && !description.isUpdateable())) {
                throw new InventoryAccessException(
                    'You do not have permission to change one or more required inventory fields.'
                );
            }
        }
    }

    private class GoodsReceiptLineInput {
        Id dispatchLineId;
        Id orderLineId;
        Boolean linkDispatchLine = false;
        Id productId;
        String productName;
        Decimal expectedQuantity;
        Decimal receivedQuantity;
        Decimal damagedQuantity;
        Decimal acceptedQuantity;
        List<GoodsReceiptBatchInput> batchAllocations;
        Boolean batchTracked = false;
    }

    private class GoodsReceiptBatchInput {
        String batchNumber;
        Date manufacturingDate;
        Date expiryDate;
        Decimal receivedQuantity;
        Decimal damagedQuantity;
        Id productId;
        Id productBatchId;
        String batchKey;
    }

    private static List<GoodsReceiptBatchInput> parseReceiptBatchAllocations(
        Object rawBatches
    ) {
        List<GoodsReceiptBatchInput> allocations =
            new List<GoodsReceiptBatchInput>();
        if (rawBatches == null) return allocations;
        if (!(rawBatches instanceof List<Object>)) {
            throw new InventoryRequestException(
                'Batch allocations must be provided as a list.'
            );
        }
        for (Object rawBatch : (List<Object>) rawBatches) {
            if (!(rawBatch instanceof Map<String, Object>)) {
                throw new InventoryRequestException(
                    'Each batch allocation must be a valid object.'
                );
            }
            Map<String, Object> batchMap = (Map<String, Object>) rawBatch;
            GoodsReceiptBatchInput allocation = new GoodsReceiptBatchInput();
            allocation.batchNumber = stringValue(batchMap.get('batchNumber'));
            if (!String.isBlank(allocation.batchNumber)) {
                allocation.batchNumber = allocation.batchNumber.trim();
            }
            validateLength(
                allocation.batchNumber,
                Schema.sObjectType.Product_Batch__c.fields.Name.getLength(),
                'Batch number'
            );
            allocation.manufacturingDate = optionalDateValue(
                batchMap.get('manufacturingDate'),
                'Manufacturing date'
            );
            allocation.expiryDate = optionalDateValue(
                batchMap.get('expiryDate'),
                'Expiry date'
            );
            allocation.receivedQuantity = decimalValue(
                batchMap.get('receivedQuantity'),
                'Batch received quantity'
            );
            allocation.damagedQuantity = decimalValue(
                batchMap.get('damagedQuantity'),
                'Batch damaged quantity'
            );
            if (String.isBlank(allocation.batchNumber)
                || allocation.receivedQuantity <= 0
                || allocation.damagedQuantity < 0
                || allocation.damagedQuantity > allocation.receivedQuantity
                || allocation.expiryDate == null
                || (allocation.manufacturingDate != null
                    && allocation.expiryDate < allocation.manufacturingDate)) {
                throw new InventoryRequestException(
                    'Each batch requires a batch number, positive received quantity, valid expiry date, and damaged quantity no greater than received quantity.'
                );
            }
            allocations.add(allocation);
        }
        return allocations;
    }

    private static Date optionalDateValue(Object rawValue, String label) {
        String value = stringValue(rawValue);
        if (String.isBlank(value)) return null;
        try {
            return Date.valueOf(value);
        } catch (Exception error) {
            throw new InventoryRequestException(label + ' must be a valid date.');
        }
    }

    private static void validateReceiptBatchAllocations(
        GoodsReceiptLineInput receiptLine,
        Boolean batchTracked
    ) {
        if (!batchTracked) {
            if (!receiptLine.batchAllocations.isEmpty()) {
                throw new InventoryRequestException(
                    'Batch details can only be recorded for products marked as batch tracked.'
                );
            }
            return;
        }
        if (receiptLine.receivedQuantity == 0) {
            if (!receiptLine.batchAllocations.isEmpty()) {
                throw new InventoryRequestException(
                    'Batch allocations cannot be entered when no quantity was received.'
                );
            }
            return;
        }
        if (receiptLine.batchAllocations.isEmpty()) {
            throw new InventoryRequestException(
                'Enter batch number and expiry details for this batch-tracked product.'
            );
        }
        Decimal allocatedReceived = 0;
        Decimal allocatedDamaged = 0;
        for (GoodsReceiptBatchInput allocation : receiptLine.batchAllocations) {
            allocatedReceived += allocation.receivedQuantity;
            allocatedDamaged += allocation.damagedQuantity;
            allocation.productId = receiptLine.productId;
        }
        if (allocatedReceived != receiptLine.receivedQuantity
            || allocatedDamaged != receiptLine.damagedQuantity) {
            throw new InventoryRequestException(
                'Batch allocations must add up to the received and damaged quantities on the GRN line.'
            );
        }
    }

    private static String receiptBatchFingerprint(
        List<GoodsReceiptBatchInput> allocations
    ) {
        List<String> values = new List<String>();
        for (GoodsReceiptBatchInput allocation : allocations) {
            values.add(
                allocation.batchNumber + ':' +
                String.valueOf(allocation.manufacturingDate) + ':' +
                String.valueOf(allocation.expiryDate) + ':' +
                String.valueOf(allocation.receivedQuantity) + ':' +
                String.valueOf(allocation.damagedQuantity)
            );
        }
        values.sort();
        return String.join(values, ',');
    }

    private class InventoryRequestException extends Exception {}
    private class InventoryConflictException extends Exception {}
    private class InventoryAccessException extends Exception {}
    private class InventoryConfigurationException extends Exception {}
}
