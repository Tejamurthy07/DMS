@IsTest
private class DMSDistributorInventoryResourceTest {
    private static final String DISTRIBUTOR_TOKEN =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    private static final String OTHER_DISTRIBUTOR_TOKEN =
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

    @IsTest
    static void inventoryResponseIsScopedToAuthenticatedDistributor() {
        Account distributor = createDistributor('Inventory Distributor', DISTRIBUTOR_TOKEN);
        Account otherDistributor = createDistributor(
            'Other Inventory Distributor',
            OTHER_DISTRIBUTOR_TOKEN
        );
        Warehouse__c distributorWarehouse = new Warehouse__c(
            Name = 'Distributor Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c otherWarehouse = new Warehouse__c(
            Name = 'Other Distributor Warehouse',
            Distributor__c = otherDistributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{ distributorWarehouse, otherWarehouse };

        Product2 product = new Product2(
            Name = 'Inventory Test Product',
            ProductCode = 'INV-TEST',
            IsActive = true,
            Category__c = 'Beverages'
        );
        insert product;

        Inventory__c distributorInventory = new Inventory__c(
            Warehouse__c = distributorWarehouse.Id,
            Product__c = product.Id,
            Available_Quantity__c = 8,
            Reserved_Quantity__c = 2,
            Minimum_Stock_Level__c = 10
        );
        Inventory__c otherInventory = new Inventory__c(
            Warehouse__c = otherWarehouse.Id,
            Product__c = product.Id,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 5
        );
        insert new List<Inventory__c>{ distributorInventory, otherInventory };

        insert new List<Product_Batch__c>{
            new Product_Batch__c(
                Name = 'INV-TEST-BATCH',
                Product__c = product.Id,
                Warehouse__c = distributorWarehouse.Id,
                Manufacturing_Date__c = Date.today().addDays(-60),
                Expiry_Date__c = Date.today().addDays(15),
                Batch_Quantity__c = 8
            ),
            new Product_Batch__c(
                Name = 'INV-EXPIRED-BATCH',
                Product__c = product.Id,
                Warehouse__c = distributorWarehouse.Id,
                Manufacturing_Date__c = Date.today().addDays(-100),
                Expiry_Date__c = Date.today().addDays(-1),
                Batch_Quantity__c = 3
            ),
            new Product_Batch__c(
                Name = 'INV-OTHER-BATCH',
                Product__c = product.Id,
                Warehouse__c = otherWarehouse.Id,
                Manufacturing_Date__c = Date.today().addDays(-60),
                Expiry_Date__c = Date.today().addDays(15),
                Batch_Quantity__c = 100
            )
        };

        insert new List<Inventory_Transaction__c>{
            new Inventory_Transaction__c(
                Inventory__c = distributorInventory.Id,
                Transaction_Type__c = 'Primary Order Receipt',
                Quantity__c = 5,
                Transaction_Date__c = System.now(),
                Reference_Number__c = 'GRN-TEST-1'
            ),
            new Inventory_Transaction__c(
                Inventory__c = otherInventory.Id,
                Transaction_Type__c = 'Secondary Order Sale',
                Quantity__c = 50,
                Transaction_Date__c = System.now(),
                Reference_Number__c = 'INV-OTHER-1'
            )
        };

        insert new List<Goods_Receipt_Note__c>{
            new Goods_Receipt_Note__c(
                Distributor__c = distributor.Id,
                Warehouse__c = distributorWarehouse.Id,
                GRN_Date__c = Date.today(),
                Received_Quantity__c = 5,
                Damaged_Quantity__c = 0,
                GRN_Status__c = 'Submitted'
            ),
            new Goods_Receipt_Note__c(
                Distributor__c = otherDistributor.Id,
                Warehouse__c = otherWarehouse.Id,
                GRN_Date__c = Date.today(),
                Received_Quantity__c = 50,
                Damaged_Quantity__c = 0,
                GRN_Status__c = 'Submitted'
            )
        };

        setRequest(DISTRIBUTOR_TOKEN);
        Test.startTest();
        DMSDistributorInventoryResource.getInventory();
        Test.stopTest();

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Map<String, Object> summary = (Map<String, Object>) payload.get('summary');
        List<Object> stock = (List<Object>) payload.get('stock');
        List<Object> warehouses = (List<Object>) payload.get('warehouses');
        List<Object> batches = (List<Object>) payload.get('batches');
        List<Object> transactions = (List<Object>) payload.get('transactions');
        List<Object> grns = (List<Object>) payload.get('recentGrns');

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, stock.size());
        System.assertEquals(1, warehouses.size());
        System.assertEquals(2, batches.size());
        System.assertEquals(1, transactions.size());
        System.assertEquals(1, grns.size());
        System.assertEquals(1, summary.get('totalProducts'));
        System.assertEquals(10, summary.get('totalStockOnHand'));
        System.assertEquals(8, summary.get('availableStock'));
        System.assertEquals(2, summary.get('reservedStock'));
        System.assertEquals(1, summary.get('lowStockProducts'));
        System.assertEquals(1, summary.get('expiringSoonBatches'));
        System.assertEquals(1, summary.get('expiredBatches'));
        System.assertEquals(5, summary.get('stockReceivedToday'));
        System.assertEquals(0, summary.get('stockSoldToday'));
    }

    @IsTest
    static void inventoryEndpointReturnsEmptyCollectionsAndZeroTotals() {
        createDistributor('Empty Inventory Distributor', DISTRIBUTOR_TOKEN);
        setRequest(DISTRIBUTOR_TOKEN);

        Test.startTest();
        DMSDistributorInventoryResource.getInventory();
        Test.stopTest();

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Map<String, Object> summary = (Map<String, Object>) payload.get('summary');

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, summary.get('totalProducts'));
        System.assertEquals(0, summary.get('totalStockOnHand'));
        System.assertEquals(0, summary.get('availableStock'));
        System.assertEquals(0, summary.get('reservedStock'));
        System.assertEquals(0, ((List<Object>) payload.get('stock')).size());
        System.assertEquals(0, ((List<Object>) payload.get('batches')).size());
    }

    @IsTest
    static void inventoryEndpointRejectsInvalidAndExpiredSessions() {
        createDistributor(
            'Expired Inventory Distributor',
            DISTRIBUTOR_TOKEN,
            System.now().addMinutes(-1)
        );

        setRequest(DISTRIBUTOR_TOKEN);
        DMSDistributorInventoryResource.getInventory();
        System.assertEquals(401, RestContext.response.statusCode);

        setRequest(OTHER_DISTRIBUTOR_TOKEN);
        RestContext.response = new RestResponse();
        DMSDistributorInventoryResource.getInventory();
        System.assertEquals(401, RestContext.response.statusCode);

        RestContext.request = new RestRequest();
        RestContext.request.headers.put('x-dms-session', 'invalid');
        RestContext.response = new RestResponse();
        DMSDistributorInventoryResource.getInventory();
        System.assertEquals(401, RestContext.response.statusCode);
    }

    @IsTest
    static void warehouseCreationUsesSalesforceGeneratedCodes() {
        Account distributor = createDistributor('Warehouse Test Distributor', DISTRIBUTOR_TOKEN);
        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'createWarehouse',
            'name' => 'North Depot',
            'city' => 'Pune'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);

        Warehouse__c createdWarehouse = [
            SELECT Id, Name, Warehouse_Code__c, Distributor__c, Warehouse_Status__c
            FROM Warehouse__c
            WHERE Distributor__c = :distributor.Id
            LIMIT 1
        ];
        System.assertEquals('North Depot', createdWarehouse.Name);
        System.assertNotEquals(null, createdWarehouse.Warehouse_Code__c);
        System.assertEquals(distributor.Id, createdWarehouse.Distributor__c);
        System.assertEquals('Active', createdWarehouse.Warehouse_Status__c);
    }

    @IsTest
    static void stockReceiptIsAuditedAndIdempotentAndBlocksUnsafeDeactivation() {
        Account distributor = createDistributor('Stock Movement Distributor', DISTRIBUTOR_TOKEN);
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Stock Movement Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Product2 product = new Product2(
            Name = 'Stock Movement Product',
            ProductCode = 'MOVE-PROD',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert product;

        Map<String, Object> receipt = new Map<String, Object>{
            'action' => 'receiveStock',
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'quantity' => 5,
            'referenceNumber' => 'GRN-MOVE-001',
            'reason' => 'Initial authorized receipt'
        };
        setPostRequest(DISTRIBUTOR_TOKEN, receipt);
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c balance = [
            SELECT Id, Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouse.Id AND Product__c = :product.Id
            LIMIT 1
        ];
        System.assertEquals(5, balance.Available_Quantity__c);
        System.assertEquals(0, balance.Reserved_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
              AND Reference_Number__c = 'GRN-MOVE-001'
              AND Transaction_Type__c = 'Primary Order Receipt'
        ]);

        setPostRequest(DISTRIBUTOR_TOKEN, receipt);
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Available_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id AND Reference_Number__c = 'GRN-MOVE-001'
        ]);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'updateWarehouse',
            'warehouseId' => warehouse.Id,
            'status' => 'Inactive'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals('Active', [
            SELECT Warehouse_Status__c FROM Warehouse__c WHERE Id = :warehouse.Id
        ].Warehouse_Status__c);
    }

    @IsTest
    static void warehouseUpdatesAreScopedAndValidateRequiredName() {
        Account distributor = createDistributor('Warehouse Update Distributor', DISTRIBUTOR_TOKEN);
        Account otherDistributor = createDistributor(
            'Other Warehouse Update Distributor',
            OTHER_DISTRIBUTOR_TOKEN
        );
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Original Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c otherWarehouse = new Warehouse__c(
            Name = 'Other Warehouse',
            Distributor__c = otherDistributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{warehouse, otherWarehouse};

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'updateWarehouse',
            'warehouseId' => warehouse.Id,
            'name' => '',
            'city' => 'Pune'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'updateWarehouse',
            'warehouseId' => warehouse.Id,
            'name' => 'Updated Warehouse',
            'city' => 'Pune'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);
        Warehouse__c updatedWarehouse = [
            SELECT Name, City__c FROM Warehouse__c WHERE Id = :warehouse.Id
        ];
        System.assertEquals('Updated Warehouse', updatedWarehouse.Name);
        System.assertEquals('Pune', updatedWarehouse.City__c);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'updateWarehouse',
            'warehouseId' => otherWarehouse.Id,
            'name' => 'Cross-account edit'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals('Other Warehouse', [
            SELECT Name FROM Warehouse__c WHERE Id = :otherWarehouse.Id
        ].Name);
    }

    @IsTest
    static void stockAdjustmentsProtectReservedAndNonnegativeQuantities() {
        Account distributor = createDistributor('Stock Adjustment Distributor', DISTRIBUTOR_TOKEN);
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Stock Adjustment Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Product2 product = new Product2(
            Name = 'Stock Adjustment Product',
            ProductCode = 'ADJUST-PROD',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert product;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = product.Id,
            Available_Quantity__c = 5,
            Reserved_Quantity__c = 2,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'adjustStock',
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'quantity' => 6,
            'direction' => 'decrease',
            'referenceNumber' => 'ADJ-TOO-LARGE',
            'reason' => 'Count correction'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(409, RestContext.response.statusCode);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'adjustStock',
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'quantity' => 2,
            'direction' => 'decrease',
            'referenceNumber' => 'ADJ-MISSING-REASON'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'adjustStock',
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'quantity' => 3,
            'direction' => 'increase',
            'referenceNumber' => 'ADJ-INCREASE',
            'reason' => 'Physical count increase'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setPostRequest(DISTRIBUTOR_TOKEN, new Map<String, Object>{
            'action' => 'adjustStock',
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'quantity' => 2,
            'direction' => 'decrease',
            'referenceNumber' => 'ADJ-DECREASE',
            'reason' => 'Physical count decrease'
        });
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);

        Inventory__c adjustedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ];
        System.assertEquals(6, adjustedBalance.Available_Quantity__c);
        System.assertEquals(2, adjustedBalance.Reserved_Quantity__c);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
              AND Transaction_Type__c = 'Stock Adjustment'
        ]);
    }

    @IsTest
    static void stockTransfersMoveBothBalancesAndReplaySafely() {
        Account distributor = createDistributor('Stock Transfer Distributor', DISTRIBUTOR_TOKEN);
        Warehouse__c source = new Warehouse__c(
            Name = 'Transfer Source',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c destination = new Warehouse__c(
            Name = 'Transfer Destination',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{source, destination};
        Product2 product = new Product2(
            Name = 'Stock Transfer Product',
            ProductCode = 'TRANSFER-PROD',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert product;
        Inventory__c sourceBalance = new Inventory__c(
            Warehouse__c = source.Id,
            Product__c = product.Id,
            Available_Quantity__c = 10,
            Reserved_Quantity__c = 2,
            Minimum_Stock_Level__c = 1
        );
        insert sourceBalance;
        Map<String, Object> transfer = new Map<String, Object>{
            'action' => 'transferStock',
            'sourceWarehouseId' => source.Id,
            'destinationWarehouseId' => destination.Id,
            'productId' => product.Id,
            'quantity' => 4,
            'referenceNumber' => 'TRANSFER-001',
            'reason' => 'Balance the stock'
        };

        setPostRequest(DISTRIBUTOR_TOKEN, transfer);
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);
        Inventory__c movedSource = [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :sourceBalance.Id
        ];
        Inventory__c movedDestination = [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :destination.Id AND Product__c = :product.Id
        ];
        System.assertEquals(6, movedSource.Available_Quantity__c);
        System.assertEquals(4, movedDestination.Available_Quantity__c);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = 'TRANSFER-001'
              AND Transaction_Type__c = 'Stock Transfer'
        ]);

        setPostRequest(DISTRIBUTOR_TOKEN, transfer);
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, parseResponse().get('alreadyProcessed'));

        transfer.put('quantity', 20);
        transfer.put('referenceNumber', 'TRANSFER-INSUFFICIENT');
        setPostRequest(DISTRIBUTOR_TOKEN, transfer);
        DMSDistributorInventoryResource.postInventoryAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(6, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :sourceBalance.Id
        ].Available_Quantity__c);
    }

    @IsTest
    static void goodsReceiptPostsAcceptedStockAndRetriesWithoutDuplicateMovements() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        Id orderId = data.get('orderId');
        Id dispatchId = data.get('dispatchId');
        Id dispatchLineId = data.get('dispatchLineId');
        User apiUser = createInventoryApiUser();
        Inventory__c startingBalance = new Inventory__c(
            Warehouse__c = data.get('warehouseId'),
            Product__c = data.get('productId'),
            Available_Quantity__c = 7,
            Reserved_Quantity__c = 2,
            Minimum_Stock_Level__c = 1
        );
        insert startingBalance;
        Map<String, Object> payload = goodsReceiptPayload(
            data,
            'GRN-REQUEST-1',
            4,
            1
        );

        Test.startTest();
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = parseResponse();
        System.assertEquals(false, result.get('alreadyProcessed'));
        Id goodsReceiptId = (Id) result.get('grnId');
        System.assertNotEquals(null, goodsReceiptId);
        Goods_Receipt_Note__c goodsReceipt = [
            SELECT Name, GRN_Status__c, DMS_Dispatch__c, Expected_Quantity__c, Received_Quantity__c,
                   Damaged_Quantity__c, Accepted_Quantity__c
            FROM Goods_Receipt_Note__c
            WHERE Id = :goodsReceiptId
        ];
        System.assertEquals('Approved', goodsReceipt.GRN_Status__c);
        System.assertEquals(data.get('dispatchId'), goodsReceipt.DMS_Dispatch__c);
        System.assertEquals(10, goodsReceipt.Expected_Quantity__c);
        System.assertEquals(4, goodsReceipt.Received_Quantity__c);
        System.assertEquals(1, goodsReceipt.Damaged_Quantity__c);
        System.assertEquals(3, goodsReceipt.Accepted_Quantity__c);
        Goods_Receipt_Line_Item__c receiptLine = [
            SELECT DMS_Dispatch_Line__c, Order_Line_Item__c,
                   Received_Quantity__c, Damaged_Quantity__c,
                   Accepted_Quantity__c
            FROM Goods_Receipt_Line_Item__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
            LIMIT 1
        ];
        System.assertEquals(data.get('dispatchLineId'), receiptLine.DMS_Dispatch_Line__c);
        System.assertEquals(data.get('orderLineId'), receiptLine.Order_Line_Item__c);
        System.assertEquals(3, receiptLine.Accepted_Quantity__c);
        Inventory__c postedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :startingBalance.Id
        ];
        System.assertEquals(10, postedBalance.Available_Quantity__c);
        System.assertEquals(2, postedBalance.Reserved_Quantity__c);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
        ]);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
              AND Transaction_Type__c = 'Primary Order Receipt'
              AND Quantity__c = 3
        ]);
        for (Inventory_Transaction__c inventoryTransaction : [
            SELECT Reference_Number__c
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
        ]) {
            System.assert(
                inventoryTransaction.Reference_Number__c.startsWith(goodsReceipt.Name + '-'),
                'GRN inventory transactions should use the assigned GRN number.'
            );
        }

        setRequest(DISTRIBUTOR_TOKEN);
        RestContext.request.params.put('view', 'orderReceipts');
        RestContext.request.params.put('orderId', String.valueOf(orderId));
        DMSDistributorInventoryResource.getInventory();
        List<Object> receiptDispatches =
            (List<Object>) parseResponse().get('dispatches');
        System.assertEquals(1, receiptDispatches.size());
        Map<String, Object> receiptDispatch =
            (Map<String, Object>) receiptDispatches[0];
        List<Object> receiptDispatchLines =
            (List<Object>) receiptDispatch.get('lines');
        Map<String, Object> receiptDispatchLine =
            (Map<String, Object>) receiptDispatchLines[0];
        System.assertEquals(
            4,
            receiptDispatchLine.get('receivedQuantityToDate')
        );
        System.assertEquals(
            6,
            receiptDispatchLine.get('remainingQuantity')
        );

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, parseResponse().get('alreadyProcessed'));
        System.assertEquals(10, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :startingBalance.Id
        ].Available_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Goods_Receipt_Note__c
            WHERE Order__c = :orderId
        ]);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
        ]);
        DMS_Dispatch_Line__c synchronizedLine = [
            SELECT Quantity__c, Quantity_Delivered__c, Quantity_Damaged__c,
                   Quantity_Short__c
            FROM DMS_Dispatch_Line__c
            WHERE Id = :dispatchLineId
        ];
        System.assertEquals(10, synchronizedLine.Quantity__c);
        System.assertEquals(4, synchronizedLine.Quantity_Delivered__c);
        System.assertEquals(1, synchronizedLine.Quantity_Damaged__c);
        System.assertEquals(6, synchronizedLine.Quantity_Short__c);
        DMS_Dispatch__c synchronizedDispatch = [
            SELECT Status__c, Delivery_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
        ];
        System.assertEquals('Dispatched', synchronizedDispatch.Status__c);
        System.assertEquals('Partially Delivered', synchronizedDispatch.Delivery_Status__c);

        payload.put('remarks', 'Changed payload');
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(10, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :startingBalance.Id
        ].Available_Quantity__c);
    }

    @IsTest
    static void goodsReceiptPreservesPaidFreeLinesAndAggregatesMultipleReceipts() {
        Map<String, Id> data = createGoodsReceiptOrder(
            DISTRIBUTOR_TOKEN,
            true
        );
        Id dispatchId = data.get('dispatchId');
        Id dispatchLineId = data.get('dispatchLineId');
        Id freeDispatchLineId = data.get('freeDispatchLineId');
        Id secondProductDispatchLineId = data.get('secondProductDispatchLineId');
        Id orderId = data.get('orderId');
        Id orderLineId = data.get('orderLineId');
        Id freeOrderLineId = data.get('freeOrderLineId');
        Id secondProductOrderLineId = data.get('secondProductOrderLineId');
        Id warehouseId = data.get('warehouseId');
        Id productId = data.get('productId');
        Id secondProductId = data.get('secondProductId');
        User apiUser = createInventoryApiUser();
        Map<String, Object> firstReceipt = goodsReceiptPayload(
            data,
            'GRN-MULTI-1',
            new List<Object>{
                goodsReceiptLine(data.get('dispatchLineId'), data.get('orderLineId'), 19, 2),
                goodsReceiptLine(
                    data.get('freeDispatchLineId'),
                    data.get('freeOrderLineId'),
                    5,
                    0
                ),
                goodsReceiptLine(
                    data.get('secondProductDispatchLineId'),
                    data.get('secondProductOrderLineId'),
                    6,
                    1
                )
            }
        );

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, firstReceipt);
        System.assertEquals(200, RestContext.response.statusCode);
        Goods_Receipt_Note__c firstGrn = [
            SELECT Id, Expected_Quantity__c, Received_Quantity__c,
                   Damaged_Quantity__c, Accepted_Quantity__c
            FROM Goods_Receipt_Note__c
            WHERE Request_Key__c != null
            LIMIT 1
        ];
        System.assertEquals(34, firstGrn.Expected_Quantity__c);
        System.assertEquals(30, firstGrn.Received_Quantity__c);
        System.assertEquals(3, firstGrn.Damaged_Quantity__c);
        System.assertEquals(27, firstGrn.Accepted_Quantity__c);
        Map<Id, DMS_Dispatch_Line__c> linesById = new Map<Id, DMS_Dispatch_Line__c>([
            SELECT Id, Order_Line_Item__c, Product__c, Quantity__c,
                   Quantity_Delivered__c, Quantity_Damaged__c, Quantity_Short__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatchId
        ]);
        DMS_Dispatch_Line__c paidLine = linesById.get(data.get('dispatchLineId'));
        DMS_Dispatch_Line__c freeLine = linesById.get(data.get('freeDispatchLineId'));
        DMS_Dispatch_Line__c secondProductLine =
            linesById.get(data.get('secondProductDispatchLineId'));
        System.assertEquals(data.get('orderLineId'), paidLine.Order_Line_Item__c);
        System.assertEquals(data.get('freeOrderLineId'), freeLine.Order_Line_Item__c);
        System.assertEquals(data.get('productId'), freeLine.Product__c);
        System.assertEquals(20, paidLine.Quantity__c);
        System.assertEquals(19, paidLine.Quantity_Delivered__c);
        System.assertEquals(2, paidLine.Quantity_Damaged__c);
        System.assertEquals(1, paidLine.Quantity_Short__c);
        System.assertEquals(6, freeLine.Quantity__c);
        System.assertEquals(5, freeLine.Quantity_Delivered__c);
        System.assertEquals(1, freeLine.Quantity_Short__c);
        System.assertEquals(data.get('secondProductId'), secondProductLine.Product__c);
        System.assertEquals(2, secondProductLine.Quantity_Short__c);
        System.assertEquals('Partially Delivered', [
            SELECT Delivery_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
        ].Delivery_Status__c);
        System.assertEquals(22, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId
              AND Product__c = :productId
        ].Available_Quantity__c);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId
              AND Product__c = :secondProductId
        ].Available_Quantity__c);

        Goods_Receipt_Note__c rejectedGrn = new Goods_Receipt_Note__c(
            Distributor__c = data.get('distributorId'),
            Order__c = orderId,
            DMS_Dispatch__c = dispatchId,
            Warehouse__c = warehouseId,
            GRN_Date__c = Date.today(),
            Expected_Quantity__c = 20,
            Received_Quantity__c = 100,
            GRN_Status__c = 'Rejected'
        );
        insert rejectedGrn;
        insert new Goods_Receipt_Line_Item__c(
            Goods_Receipt_Note__c = rejectedGrn.Id,
            DMS_Dispatch_Line__c = dispatchLineId,
            Order_Line_Item__c = orderLineId,
            Product__c = productId,
            Expected_Quantity__c = 20,
            Received_Quantity__c = 100,
            Damaged_Quantity__c = 0
        );
        setRequest(DISTRIBUTOR_TOKEN);
        RestContext.request.params.put('view', 'orderReceipts');
        RestContext.request.params.put('orderId', String.valueOf(orderId));
        DMSDistributorInventoryResource.getInventory();
        List<Object> availableDispatches =
            (List<Object>) parseResponse().get('dispatches');
        Map<String, Object> availableDispatch =
            (Map<String, Object>) availableDispatches[0];
        List<Object> availableLines =
            (List<Object>) availableDispatch.get('lines');
        Map<Id, Map<String, Object>> availableByLineId =
            new Map<Id, Map<String, Object>>();
        for (Object rawAvailableLine : availableLines) {
            Map<String, Object> availableLine =
                (Map<String, Object>) rawAvailableLine;
            availableByLineId.put(
                (Id) availableLine.get('id'),
                availableLine
            );
        }
        System.assertEquals(
            'Paid',
            availableByLineId.get(dispatchLineId).get('lineType')
        );
        System.assertEquals(
            'Free',
            availableByLineId.get(freeDispatchLineId).get('lineType')
        );
        System.assertEquals(
            19,
            availableByLineId.get(dispatchLineId).get('receivedQuantityToDate')
        );

        Map<String, Object> secondReceipt = goodsReceiptPayload(
            data,
            'GRN-MULTI-2',
            new List<Object>{
                goodsReceiptLine(data.get('dispatchLineId'), data.get('orderLineId'), 1, 0),
                goodsReceiptLine(
                    data.get('freeDispatchLineId'),
                    data.get('freeOrderLineId'),
                    1,
                    0
                ),
                goodsReceiptLine(
                    data.get('secondProductDispatchLineId'),
                    data.get('secondProductOrderLineId'),
                    2,
                    0
                )
            }
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, secondReceipt);
        System.assertEquals(200, RestContext.response.statusCode);
        linesById = new Map<Id, DMS_Dispatch_Line__c>([
            SELECT Id, Quantity__c, Quantity_Delivered__c,
                   Quantity_Damaged__c, Quantity_Short__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatchId
        ]);
        System.assertEquals(20, linesById.get(dispatchLineId).Quantity__c);
        System.assertEquals(20, linesById.get(dispatchLineId).Quantity_Delivered__c);
        System.assertEquals(2, linesById.get(dispatchLineId).Quantity_Damaged__c);
        System.assertEquals(0, linesById.get(dispatchLineId).Quantity_Short__c);
        System.assertEquals(6, linesById.get(freeDispatchLineId).Quantity_Delivered__c);
        System.assertEquals(8, linesById.get(secondProductDispatchLineId).Quantity_Delivered__c);
        System.assertEquals('Delivered', [
            SELECT Delivery_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
        ].Delivery_Status__c);
        System.assertEquals(24, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId
              AND Product__c = :productId
        ].Available_Quantity__c);
        System.assertEquals(7, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouseId
              AND Product__c = :secondProductId
        ].Available_Quantity__c);

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, secondReceipt);
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, parseResponse().get('alreadyProcessed'));
        System.assertEquals(8, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__r.DMS_Dispatch__c = :dispatchId
              AND Goods_Receipt_Note__r.GRN_Status__c = 'Approved'
        ]);
        System.assertEquals(20, [
            SELECT Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Id = :dispatchLineId
        ].Quantity__c);
    }

    @IsTest
    static void goodsReceiptFullAcceptanceMarksDispatchDelivered() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        Id dispatchLineId = data.get('dispatchLineId');
        Id dispatchId = data.get('dispatchId');
        User apiUser = createInventoryApiUser();
        postInventoryActionAs(
            apiUser,
            DISTRIBUTOR_TOKEN,
            goodsReceiptPayload(data, 'GRN-FULL-ACCEPTANCE', 10, 0)
        );
        System.assertEquals(200, RestContext.response.statusCode);
        DMS_Dispatch_Line__c dispatchLine = [
            SELECT Quantity__c, Quantity_Delivered__c,
                   Quantity_Damaged__c, Quantity_Short__c
            FROM DMS_Dispatch_Line__c
            WHERE Id = :dispatchLineId
        ];
        System.assertEquals(10, dispatchLine.Quantity__c);
        System.assertEquals(10, dispatchLine.Quantity_Delivered__c);
        System.assertEquals(0, dispatchLine.Quantity_Damaged__c);
        System.assertEquals(0, dispatchLine.Quantity_Short__c);
        System.assertEquals('Delivered', [
            SELECT Delivery_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
        ].Delivery_Status__c);
        System.assertEquals('Dispatched', [
            SELECT Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
        ].Status__c);
    }

    @IsTest
    static void goodsReceiptCreatesAndUpdatesBatchBalancesIdempotently() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        update new Product2(
            Id = data.get('productId'),
            Batch_Tracked__c = true
        );
        User apiUser = createInventoryApiUser();
        Map<String, Object> line = goodsReceiptLine(
            data.get('dispatchLineId'),
            data.get('orderLineId'),
            5,
            1
        );
        line.put('batches', new List<Object>{
            goodsReceiptBatch('GRN-BATCH-A', 2, 0, Date.today().addDays(90)),
            goodsReceiptBatch('GRN-BATCH-B', 3, 1, Date.today().addDays(120))
        });
        Map<String, Object> payload = goodsReceiptPayload(
            data,
            'GRN-BATCH-REQUEST',
            new List<Object>{ line }
        );

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(200, RestContext.response.statusCode);
        Id goodsReceiptId = (Id) parseResponse().get('grnId');

        List<Product_Batch__c> batches = [
            SELECT Id, Name, Batch_Key__c, Batch_Quantity__c,
                   Product__c, Warehouse__c, Expiry_Date__c
            FROM Product_Batch__c
            WHERE Product__c = :data.get('productId')
            ORDER BY Name
        ];
        System.assertEquals(2, batches.size());
        System.assertEquals('GRN-BATCH-A', batches[0].Name);
        System.assertEquals(2, batches[0].Batch_Quantity__c);
        System.assertEquals('GRN-BATCH-B', batches[1].Name);
        System.assertEquals(2, batches[1].Batch_Quantity__c);
        System.assertNotEquals(null, batches[0].Batch_Key__c);
        System.assertEquals(data.get('warehouseId'), batches[0].Warehouse__c);
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Goods_Receipt_Line_Item__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
              AND Product_Batch__c != null
        ]);
        System.assertEquals(3, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Goods_Receipt_Note__c = :goodsReceiptId
              AND Product_Batch__c != null
        ]);
        System.assertEquals(4, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :data.get('warehouseId')
              AND Product__c = :data.get('productId')
        ].Available_Quantity__c);

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, parseResponse().get('alreadyProcessed'));
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Product_Batch__c
            WHERE Product__c = :data.get('productId')
        ]);
        AggregateResult batchTotals = [
            SELECT SUM(Batch_Quantity__c) totalQuantity
            FROM Product_Batch__c
            WHERE Product__c = :data.get('productId')
        ];
        System.assertEquals(4, (Decimal) batchTotals.get('totalQuantity'));

        Map<String, Object> missingBatch = goodsReceiptPayload(
            data,
            'GRN-BATCH-MISSING',
            1,
            0
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, missingBatch);
        System.assertEquals(400, RestContext.response.statusCode);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Goods_Receipt_Note__c
            WHERE Request_Key__c != null
        ]);
    }

    @IsTest
    static void goodsReceiptRejectsDispatchLineWithoutReliableMatch() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        Map<String, Id> otherData = createGoodsReceiptOrder(OTHER_DISTRIBUTOR_TOKEN);
        Id dispatchLineId = data.get('dispatchLineId');
        User apiUser = createInventoryApiUser();
        Map<String, Object> payload = goodsReceiptPayload(
            data,
            'GRN-WRONG-DISPATCH-LINE',
            1,
            0
        );
        List<Object> lines = (List<Object>) payload.get('lines');
        Map<String, Object> line = (Map<String, Object>) lines[0];
        line.put('dispatchLineId', otherData.get('dispatchLineId'));

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt_Note__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Inventory_Transaction__c]);
        System.assertEquals(10, [
            SELECT Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Id = :dispatchLineId
        ].Quantity__c);
    }

    @IsTest
    static void goodsReceiptAllowsMissingDispatchAndDispatchLineOrderLookups() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        update new DMS_Dispatch_Line__c(
            Id = data.get('dispatchLineId'),
            Order_Line_Item__c = null
        );
        User apiUser = createInventoryApiUser();
        Map<String, Object> payload = goodsReceiptPayload(
            data,
            'GRN-OPTIONAL-ORDER-LINE',
            2,
            0
        );
        List<Object> lines = (List<Object>) payload.get('lines');
        Map<String, Object> line = (Map<String, Object>) lines[0];
        line.remove('dispatchLineId');

        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);

        System.assertEquals(200, RestContext.response.statusCode);
        Goods_Receipt_Line_Item__c receiptLine = [
            SELECT DMS_Dispatch_Line__c, Order_Line_Item__c, Product__c,
                   Expected_Quantity__c, Received_Quantity__c
            FROM Goods_Receipt_Line_Item__c
            LIMIT 1
        ];
        System.assertEquals(null, receiptLine.DMS_Dispatch_Line__c);
        System.assertEquals(data.get('orderLineId'), receiptLine.Order_Line_Item__c);
        System.assertEquals(data.get('productId'), receiptLine.Product__c);
        System.assertEquals(10, receiptLine.Expected_Quantity__c);
        System.assertEquals(2, receiptLine.Received_Quantity__c);
        System.assertEquals(2, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :data.get('warehouseId')
              AND Product__c = :data.get('productId')
            LIMIT 1
        ].Available_Quantity__c);
    }

    @IsTest
    static void goodsReceiptRejectsOverReceiptAndInvalidDamage() {
        Map<String, Id> data = createGoodsReceiptOrder(DISTRIBUTOR_TOKEN);
        User apiUser = createInventoryApiUser();
        Map<String, Object> overReceipt = goodsReceiptPayload(
            data,
            'GRN-OVER-RECEIPT',
            11,
            0
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, overReceipt);
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt_Note__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Inventory__c]);

        Map<String, Object> invalidDamage = goodsReceiptPayload(
            data,
            'GRN-INVALID-DAMAGE',
            2,
            3
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, invalidDamage);
        System.assertEquals(400, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt_Note__c]);

        Map<String, Object> negativeQuantity = goodsReceiptPayload(
            data,
            'GRN-NEGATIVE-QUANTITY',
            -1,
            0
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, negativeQuantity);
        System.assertEquals(400, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt_Note__c]);
    }

    @IsTest
    static void goodsReceiptCannotUseAnotherDistributorsOrderOrWarehouse() {
        Map<String, Id> otherData = createGoodsReceiptOrder(OTHER_DISTRIBUTOR_TOKEN);
        createDistributor('Goods Receipt Scope Distributor', DISTRIBUTOR_TOKEN);
        User apiUser = createInventoryApiUser();
        Map<String, Object> payload = goodsReceiptPayload(
            otherData,
            'GRN-CROSS-DISTRIBUTOR',
            1,
            0
        );
        postInventoryActionAs(apiUser, DISTRIBUTOR_TOKEN, payload);
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Goods_Receipt_Note__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Inventory__c]);
    }

    private static Map<String, Id> createGoodsReceiptOrder(String token) {
        return createGoodsReceiptOrder(token, false);
    }

    private static Map<String, Id> createGoodsReceiptOrder(
        String token,
        Boolean includePaidFreeAndSecondProduct
    ) {
        Account distributor = createDistributor(
            'Goods Receipt Distributor ' + token.substring(0, 4),
            token
        );
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Goods Receipt Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Product2 product = new Product2(
            Name = 'Goods Receipt Product',
            ProductCode = 'GRN-TEST-PRODUCT',
            IsActive = true,
            SFA_Product__c = true
        );
        List<Product2> products = new List<Product2>{ product };
        Product2 secondProduct;
        if (includePaidFreeAndSecondProduct) {
            secondProduct = new Product2(
                Name = 'Second Goods Receipt Product',
                ProductCode = 'GRN-TEST-PRODUCT-2',
                IsActive = true,
                SFA_Product__c = true
            );
            products.add(secondProduct);
        }
        insert products;
        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 currentProduct : products) {
            entries.add(new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = currentProduct.Id,
                UnitPrice = 10,
                IsActive = true
            ));
        }
        insert entries;
        Order salesOrder = new Order(
            AccountId = distributor.Id,
            Type = 'Primary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = standardPricebookId,
            DMS_Fulfillment_Warehouse__c = warehouse.Id
        );
        insert salesOrder;
        Decimal paidQuantity = includePaidFreeAndSecondProduct ? 20 : 10;
        OrderItem paidOrderLine = new OrderItem(
            OrderId = salesOrder.Id,
            PricebookEntryId = entries[0].Id,
            Quantity = paidQuantity,
            UnitPrice = 10,
            Paid_Quantity__c = paidQuantity,
            Free_Quantity__c = 0,
            Unit_of_Measure__c = 'Case'
        );
        List<OrderItem> orderLines = new List<OrderItem>{ paidOrderLine };
        OrderItem freeOrderLine;
        OrderItem secondProductOrderLine;
        if (includePaidFreeAndSecondProduct) {
            freeOrderLine = new OrderItem(
                OrderId = salesOrder.Id,
                PricebookEntryId = entries[0].Id,
                Quantity = 6,
                UnitPrice = 0,
                Paid_Quantity__c = 0,
                Free_Quantity__c = 6,
                Unit_of_Measure__c = 'Case'
            );
            secondProductOrderLine = new OrderItem(
                OrderId = salesOrder.Id,
                PricebookEntryId = entries[1].Id,
                Quantity = 8,
                UnitPrice = 10,
                Paid_Quantity__c = 8,
                Free_Quantity__c = 0,
                Unit_of_Measure__c = 'Case'
            );
            orderLines.add(freeOrderLine);
            orderLines.add(secondProductOrderLine);
        }
        insert orderLines;
        update new Order(Id = salesOrder.Id, Status = 'Activated');
        DMS_Dispatch__c dispatch = new DMS_Dispatch__c(
            Distributor__c = distributor.Id,
            Order__c = salesOrder.Id,
            Warehouse__c = warehouse.Id,
            Status__c = 'Dispatched',
            Delivery_Status__c = 'In Transit'
        );
        insert dispatch;
        List<DMS_Dispatch_Line__c> dispatchLines =
            new List<DMS_Dispatch_Line__c>();
        DMS_Dispatch_Line__c paidDispatchLine = new DMS_Dispatch_Line__c(
            Dispatch__c = dispatch.Id,
            Order_Line_Item__c = paidOrderLine.Id,
            Product__c = product.Id,
            Product_Name_Snapshot__c = product.Name,
            Quantity__c = paidQuantity,
            Quantity_Delivered__c = 0,
            Quantity_Short__c = 0,
            Quantity_Damaged__c = 0,
            Unit_of_Measure__c = 'Case'
        );
        dispatchLines.add(paidDispatchLine);
        DMS_Dispatch_Line__c freeDispatchLine;
        DMS_Dispatch_Line__c secondProductDispatchLine;
        if (includePaidFreeAndSecondProduct) {
            freeDispatchLine = new DMS_Dispatch_Line__c(
                Dispatch__c = dispatch.Id,
                Order_Line_Item__c = freeOrderLine.Id,
                Product__c = product.Id,
                Product_Name_Snapshot__c = product.Name,
                Quantity__c = 6,
                Quantity_Delivered__c = 0,
                Quantity_Short__c = 0,
                Quantity_Damaged__c = 0,
                Unit_of_Measure__c = 'Case'
            );
            secondProductDispatchLine = new DMS_Dispatch_Line__c(
                Dispatch__c = dispatch.Id,
                Order_Line_Item__c = secondProductOrderLine.Id,
                Product__c = secondProduct.Id,
                Product_Name_Snapshot__c = secondProduct.Name,
                Quantity__c = 8,
                Quantity_Delivered__c = 0,
                Quantity_Short__c = 0,
                Quantity_Damaged__c = 0,
                Unit_of_Measure__c = 'Case'
            );
            dispatchLines.add(freeDispatchLine);
            dispatchLines.add(secondProductDispatchLine);
        }
        insert dispatchLines;
        Map<String, Id> data = new Map<String, Id>{
            'distributorId' => distributor.Id,
            'warehouseId' => warehouse.Id,
            'productId' => product.Id,
            'orderId' => salesOrder.Id,
            'orderLineId' => paidOrderLine.Id,
            'dispatchId' => dispatch.Id,
            'dispatchLineId' => paidDispatchLine.Id
        };
        if (includePaidFreeAndSecondProduct) {
            data.put('freeOrderLineId', freeOrderLine.Id);
            data.put('freeDispatchLineId', freeDispatchLine.Id);
            data.put('secondProductId', secondProduct.Id);
            data.put('secondProductOrderLineId', secondProductOrderLine.Id);
            data.put('secondProductDispatchLineId', secondProductDispatchLine.Id);
        }
        return data;
    }

    private static Map<String, Object> goodsReceiptPayload(
        Map<String, Id> data,
        String requestKey,
        Decimal receivedQuantity,
        Decimal damagedQuantity
    ) {
        return goodsReceiptPayload(
            data,
            requestKey,
            new List<Object>{
                goodsReceiptLine(
                    data.get('dispatchLineId'),
                    data.get('orderLineId'),
                    receivedQuantity,
                    damagedQuantity
                )
            }
        );
    }

    private static Map<String, Object> goodsReceiptPayload(
        Map<String, Id> data,
        String requestKey,
        List<Object> lines
    ) {
        return new Map<String, Object>{
            'action' => 'recordGoodsReceipt',
            'requestKey' => requestKey,
            'orderId' => data.get('orderId'),
            'dispatchId' => data.get('dispatchId'),
            'warehouseId' => data.get('warehouseId'),
            'receiptDate' => String.valueOf(Date.today()),
            'supplierDeliveryNumber' => 'DELIVERY-' + requestKey,
            'remarks' => 'Verified test delivery',
            'lines' => lines
        };
    }

    private static Map<String, Object> goodsReceiptLine(
        Id dispatchLineId,
        Id orderLineId,
        Decimal receivedQuantity,
        Decimal damagedQuantity
    ) {
        return new Map<String, Object>{
            'dispatchLineId' => dispatchLineId,
            'orderLineId' => orderLineId,
            'receivedQuantity' => receivedQuantity,
            'damagedQuantity' => damagedQuantity
        };
    }

    private static Map<String, Object> goodsReceiptBatch(
        String batchNumber,
        Decimal receivedQuantity,
        Decimal damagedQuantity,
        Date expiryDate
    ) {
        return new Map<String, Object>{
            'batchNumber' => batchNumber,
            'expiryDate' => String.valueOf(expiryDate),
            'receivedQuantity' => receivedQuantity,
            'damagedQuantity' => damagedQuantity
        };
    }

    private static User createInventoryApiUser() {
        String uniqueSuffix = String.valueOf(DateTime.now().getTime()) +
            String.valueOf(Crypto.getRandomInteger());
        User apiUser = new User(
            Alias = 'grntest',
            Email = 'grn-test@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Goods Receipt Test',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'grn-test-' + uniqueSuffix + '@example.invalid'
        );
        insert apiUser;
        PermissionSet inventoryPermissions = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'DMS_Distributor_Experience_Access'
            LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = apiUser.Id,
            PermissionSetId = inventoryPermissions.Id
        );
        return apiUser;
    }

    private static void postInventoryActionAs(
        User apiUser,
        String token,
        Map<String, Object> payload
    ) {
        System.runAs(apiUser) {
            setPostRequest(token, payload);
            DMSDistributorInventoryResource.postInventoryAction();
        }
    }

    private static Account createDistributor(String name, String token) {
        return createDistributor(name, token, System.now().addHours(1));
    }

    private static Account createDistributor(String name, String token, Datetime expiresAt) {
        Account distributor = new Account(
            Name = name,
            Email__c = name.replace(' ', '.') + '@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            DMS_Session_Token_Hash__c = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(token))
            ),
            DMS_Session_Expires_At__c = expiresAt
        );
        insert distributor;
        return distributor;
    }

    private static void setRequest(String token) {
        RestContext.request = new RestRequest();
        RestContext.request.headers.put('x-dms-session', token);
        RestContext.response = new RestResponse();
    }

    private static void setPostRequest(String token, Map<String, Object> payload) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = 'POST';
        RestContext.request.headers.put('x-dms-session', token);
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(payload));
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> parseResponse() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
    }
}
