@IsTest
private class DMSDistributorOrderResourceTest {
    private static final String TOKEN =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

    @TestSetup
    static void assignDistributorExperiencePermissions() {
        PermissionSet distributorAccess = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'DMS_Distributor_Experience_Access'
            LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = UserInfo.getUserId(),
            PermissionSetId = distributorAccess.Id
        );
    }

    @IsTest
    static void primaryPreviewConvertsUnitsAndAppliesSelectedScheme() {
        TestData data = createTestData();
        createSchemeRule(
            data.productId, 'Primary', 'Primary lower priority',
            1, 'Case', 2, 'Case', 5, Date.today().addDays(-1), Date.today().addDays(10)
        );
        Scheme_Product__c selectedScheme = createSchemeRule(
            data.productId, 'Primary', 'Primary highest priority',
            60, 'Piece', 1, 'Case', 10, Date.today().addDays(-1), Date.today().addDays(10)
        );

        Map<String, Object> payload = new Map<String, Object>{
            'action' => 'preview',
            'salesType' => 'Primary',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'pricebookEntryId' => data.primaryEntryId,
                    'quantity' => 2
                }
            }
        };
        payload.put(
            'selectedSchemeProductIds',
            new List<Object>{ String.valueOf(selectedScheme.Id) }
        );
        setPostRequest(payload);
        Test.startTest();
        DMSDistributorOrderResource.postOrder();
        Test.stopTest();

        Map<String, Object> response = parseResponse();
        Map<String, Object> preview = (Map<String, Object>) response.get('preview');
        List<Object> lines = (List<Object>) preview.get('lines');
        Map<String, Object> line = (Map<String, Object>) lines[0];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(Decimal.valueOf('2'), line.get('paidQuantity'));
        System.assertEquals(Decimal.valueOf('2'), line.get('freeQuantity'));
        System.assertEquals('Case', line.get('unitOfMeasure'));
        System.assertEquals('Primary highest priority', line.get('schemeName'));
        System.assertEquals(Decimal.valueOf('2400.00'), line.get('lineTotal'));
        System.assertEquals(Decimal.valueOf('2400.00'), preview.get('totalAmount'));
        System.assertEquals(Decimal.valueOf('240.00'), preview.get('totalTax'));
        System.assertEquals(Decimal.valueOf('2640.00'), preview.get('totalWithTax'));
        System.assertEquals(0, [SELECT COUNT() FROM Order]);
    }

    @IsTest
    static void productCatalogReturnsOnlySfaProductsFromSelectedChannelPriceBook() {
        TestData data = createTestData();
        Product2 nonSfaProduct = new Product2(
            Name = 'Non-SFA Test Product',
            ProductCode = 'NON-SFA-TEST',
            IsActive = true,
            SFA_Product__c = false,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert nonSfaProduct;
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = Test.getStandardPricebookId(),
                Product2Id = nonSfaProduct.Id,
                UnitPrice = 10,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = [
                    SELECT Id FROM Pricebook2
                    WHERE Sales_Type__c = 'Primary'
                    LIMIT 1
                ].Id,
                Product2Id = nonSfaProduct.Id,
                UnitPrice = 10,
                IsActive = true,
                Unit_of_Measure__c = 'Piece',
                Unit_Conversion_Factor__c = 1
            )
        };
        setGetRequest(new Map<String, String>{
            'view' => 'catalog',
            'type' => 'Primary'
        });

        DMSDistributorOrderResource.getOrders();

        Map<String, Object> response = parseResponse();
        List<Object> products = (List<Object>) response.get('products');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Primary', response.get('salesType'));
        System.assertEquals(1, products.size());
        Map<String, Object> product = (Map<String, Object>) products[0];
        System.assertEquals(String.valueOf(data.productId), product.get('productId'));
        System.assertEquals('DMS Primary Test Pricebook', product.get('pricebookName'));
    }

    @IsTest
    static void primaryCatalogReturnsOnlyActiveWarehousesForAuthenticatedDistributor() {
        TestData data = createTestData();
        Account otherDistributor = [
            SELECT Id
            FROM Account
            WHERE Name = 'Other Order Distributor'
            LIMIT 1
        ];
        Warehouse__c expectedWarehouse = new Warehouse__c(
            Name = 'Authorized Active Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{
            expectedWarehouse,
            new Warehouse__c(
                Name = 'Authorized Inactive Warehouse',
                Distributor__c = data.distributorId,
                Warehouse_Type__c = 'Distributor Warehouse',
                Warehouse_Status__c = 'Inactive'
            ),
            new Warehouse__c(
                Name = 'Other Distributor Warehouse',
                Distributor__c = otherDistributor.Id,
                Warehouse_Type__c = 'Distributor Warehouse',
                Warehouse_Status__c = 'Active'
            )
        };
        setGetRequest(new Map<String, String>{
            'view' => 'catalog',
            'type' => 'Primary'
        });

        DMSDistributorOrderResource.getOrders();

        Map<String, Object> response = parseResponse();
        List<Object> warehouses = (List<Object>) response.get('warehouses');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertNotEquals(null, warehouses, 'The catalog must include its warehouse list.');
        System.assertEquals(1, warehouses.size());
        Map<String, Object> warehouse = (Map<String, Object>) warehouses[0];
        System.assertEquals(String.valueOf(expectedWarehouse.Id), warehouse.get('id'));
        System.assertEquals('Authorized Active Warehouse', warehouse.get('name'));
    }

    @IsTest
    static void secondaryOrderCreationCanBeTestedWithoutAnApprovalGate() {
        TestData data = createTestData();
        Scheme_Product__c selectedScheme = createSchemeRule(
            data.productId, 'Secondary', 'Secondary pieces',
            10, 'Piece', 2, 'Piece', 10, Date.today(), Date.today().addDays(10)
        );

        Map<String, Object> payload = createPayload(
            'create',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            20,
            'secondary-order-001'
        );
        payload.put(
            'selectedSchemeProductIds',
            new List<Object>{ String.valueOf(selectedScheme.Id) }
        );
        setPostRequest(payload);
        Test.startTest();
        DMSDistributorOrderResource.postOrder();
        Test.stopTest();

        Map<String, Object> response = parseResponse();
        Map<String, Object> order = (Map<String, Object>) response.get('order');
        List<Object> lines = (List<Object>) order.get('lines');
        System.assertEquals(201, RestContext.response.statusCode);
        System.assertEquals('Secondary', order.get('salesType'));
        System.assertEquals(String.valueOf(data.retailerId), order.get('retailerId'));
        System.assertEquals('Activated', order.get('status'));
        System.assertEquals('Not Submitted', order.get('approvalStatus'));
        System.assertEquals(Decimal.valueOf('400.00'), order.get('totalAmount'));
        System.assertEquals(Decimal.valueOf('40.00'), order.get('taxAmount'));
        System.assertEquals(Decimal.valueOf('440.00'), order.get('totalWithTax'));
        System.assertEquals(2, lines.size(), 'Paid and free quantities must be saved separately.');
        Id createdOrderId = Id.valueOf((String) order.get('id'));
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :createdOrderId]
        );
        List<Order_Scheme__c> appliedSchemes = [
            SELECT Scheme__r.Scheme_Name__c, Scheme_Product__c,
                   Applied_Quantity__c, Free_Quantity__c, Discount_Amount__c, Status__c
            FROM Order_Scheme__c
            WHERE Order__c = :createdOrderId
        ];
        System.assertEquals(1, appliedSchemes.size());
        System.assertEquals('Secondary pieces', appliedSchemes[0].Scheme__r.Scheme_Name__c);
        System.assertEquals(Decimal.valueOf('20'), appliedSchemes[0].Applied_Quantity__c);
        System.assertEquals(Decimal.valueOf('4'), appliedSchemes[0].Free_Quantity__c);
        System.assertEquals('Applied', appliedSchemes[0].Status__c);

        Decimal paidQuantity = 0;
        Decimal freeQuantity = 0;
        Decimal lineTotal = 0;
        for (Object value : lines) {
            Map<String, Object> line = (Map<String, Object>) value;
            paidQuantity += line.get('paidQuantity') == null
                ? 0
                : (Decimal) line.get('paidQuantity');
            freeQuantity += line.get('freeQuantity') == null
                ? 0
                : (Decimal) line.get('freeQuantity');
            System.assertEquals('Piece', line.get('unitOfMeasure'));
            System.assertEquals('Secondary pieces', line.get('schemeName'));
            System.assertEquals(Decimal.valueOf('20.00'), line.get('listPrice'));
            lineTotal += (Decimal) line.get('lineTotal');
        }
        System.assertEquals(Decimal.valueOf('20'), paidQuantity);
        System.assertEquals(Decimal.valueOf('4'), freeQuantity);
        System.assertEquals(Decimal.valueOf('400.00'), lineTotal);
    }

    @IsTest
    static void percentageSchemeUsesExistingSchemeProductDiscountFields() {
        TestData data = createTestData();
        Scheme__c scheme = new Scheme__c(
            Scheme_Name__c = 'Secondary percentage discount',
            Scheme_Type__c = 'Percentage Discount',
            Sales_Type__c = 'Secondary',
            Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(10),
            Active__c = true,
            Status__c = 'Active'
        );
        insert scheme;
        Scheme_Product__c selectedScheme = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product__c = data.productId,
            Minimum_Quantity__c = 10,
            Minimum_Unit__c = 'Piece',
            Discount_Percentage__c = 10,
            Priority__c = 10,
            Active__c = true
        );
        insert selectedScheme;

        Map<String, Object> payload = createPayload(
            'preview',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            20,
            null
        );
        payload.put(
            'selectedSchemeProductIds',
            new List<Object>{ String.valueOf(selectedScheme.Id) }
        );
        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> preview =
            (Map<String, Object>) parseResponse().get('preview');
        Map<String, Object> line =
            (Map<String, Object>) ((List<Object>) preview.get('lines'))[0];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Secondary percentage discount', line.get('schemeName'));
        System.assertEquals(Decimal.valueOf('40.00'), line.get('discountAmount'));
        System.assertEquals(Decimal.valueOf('18.00'), line.get('netUnitPrice'));
        System.assertEquals(Decimal.valueOf('360.00'), preview.get('totalAmount'));
        System.assertEquals(Decimal.valueOf('36.00'), preview.get('totalTax'));
        System.assertEquals(Decimal.valueOf('396.00'), preview.get('totalWithTax'));
    }

    @IsTest
    static void rejectsUnauthorizedRetailersAndMultipleSchemesForOneProduct() {
        TestData data = createTestData();
        setPostRequest(createPayload(
            'preview',
            'Secondary',
            data.otherRetailerId,
            data.secondaryEntryId,
            10,
            null
        ));
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            parseResponse().get('message').toString().contains('not assigned')
        );

        setPostRequest(createPayload(
            'preview',
            'Secondary',
            data.retailerId,
            data.primaryEntryId,
            10,
            null
        ));
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(400, RestContext.response.statusCode);

        Scheme_Product__c firstScheme = createSchemeRule(
            data.productId, 'Secondary', 'Tie A',
            10, 'Piece', 1, 'Piece', 10, Date.today().addDays(-1), Date.today().addDays(10)
        );
        Scheme_Product__c secondScheme = createSchemeRule(
            data.productId, 'Secondary', 'Tie B',
            10, 'Piece', 1, 'Piece', 10, Date.today().addDays(-1), Date.today().addDays(10)
        );
        Map<String, Object> payload = createPayload(
            'preview',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            10,
            null
        );
        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();
        Map<String, Object> preview =
            (Map<String, Object>) parseResponse().get('preview');
        Map<String, Object> line =
            (Map<String, Object>) ((List<Object>) preview.get('lines'))[0];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(null, line.get('schemeName'));
        System.assertEquals(Decimal.valueOf('0'), line.get('freeQuantity'));
        System.assertEquals(null, line.get('schemeProductId'));
        System.assertEquals(Decimal.valueOf('200.00'), line.get('lineTotal'));
        System.assertEquals(Decimal.valueOf('200.00'), preview.get('subtotal'));
        System.assertEquals(Decimal.valueOf('0.00'), preview.get('discount'));
        System.assertEquals(Decimal.valueOf('200.00'), preview.get('totalAmount'));
        System.assertEquals(Decimal.valueOf('20.00'), preview.get('totalTax'));
        System.assertEquals(Decimal.valueOf('220.00'), preview.get('totalWithTax'));

        payload.put(
            'selectedSchemeProductIds',
            new List<Object>{
                String.valueOf(firstScheme.Id),
                String.valueOf(secondScheme.Id)
            }
        );
        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            parseResponse().get('message').toString().contains('only one scheme')
        );
    }

    @IsTest
    static void rejectsSelectedSchemeWhenOrderDoesNotMeetMinimumQuantity() {
        TestData data = createTestData();
        Scheme_Product__c selectedScheme = createSchemeRule(
            data.productId, 'Secondary', 'Minimum quantity scheme',
            10, 'Piece', 1, 'Piece', 10, Date.today().addDays(-1), Date.today().addDays(10)
        );
        Map<String, Object> payload = createPayload(
            'preview',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            5,
            null
        );
        payload.put(
            'selectedSchemeProductIds',
            new List<Object>{ String.valueOf(selectedScheme.Id) }
        );
        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();

        System.assertEquals(409, RestContext.response.statusCode);
        System.assert(
            parseResponse().get('message').toString().contains('does not meet the minimum')
        );
    }

    @IsTest
    static void expiredSchemesDoNotGrantFreeQuantity() {
        TestData data = createTestData();
        createSchemeRule(
            data.productId, 'Secondary', 'Expired secondary scheme',
            1, 'Piece', 5, 'Piece', 100, Date.today().addDays(-10), Date.today().addDays(-1)
        );
        createSchemeRule(
            data.productId, 'Primary', 'Primary only scheme',
            10, 'Piece', 1, 'Piece', 100, Date.today().addDays(-1), Date.today().addDays(10)
        );

        setPostRequest(createPayload(
            'preview',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            10,
            null
        ));
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> preview = (Map<String, Object>) parseResponse().get('preview');
        List<Object> lines = (List<Object>) preview.get('lines');
        Map<String, Object> line = (Map<String, Object>) lines[0];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, line.get('freeQuantity'));
        System.assertEquals(Decimal.valueOf('200.00'), line.get('lineTotal'));
        System.assertEquals(null, line.get('schemeId'));
    }

    @IsTest
    static void rejectsInvalidQuantityAndUnknownSession() {
        TestData data = createTestData();
        setPostRequest(createPayload(
            'preview',
            'Primary',
            null,
            data.primaryEntryId,
            0,
            null
        ));
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(400, RestContext.response.statusCode);

        setPostRequest(createPayload(
            'preview',
            'Primary',
            null,
            data.primaryEntryId,
            1,
            null
        ));
        RestContext.request.headers.put(
            'X-DMS-Session',
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        );
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(401, RestContext.response.statusCode);
    }

    @IsTest
    static void requestKeyMakesOrderCreationIdempotentAndHistoryIsChannelFiltered() {
        TestData data = createTestData();
        Map<String, Object> payload = createPayload(
            'create',
            'Primary',
            null,
            data.primaryEntryId,
            1,
            'primary-order-retry-key'
        );
        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(201, RestContext.response.statusCode);
        String orderId = (String) ((Map<String, Object>) parseResponse().get('order')).get('id');
        Id savedOrderId = Id.valueOf(orderId);
        Order primaryOrder = [
            SELECT Id, AccountId, Outlet__c, Type, Status
            FROM Order
            WHERE Id = :savedOrderId
            LIMIT 1
        ];
        System.assertEquals(data.distributorId, primaryOrder.AccountId);
        System.assertEquals(null, primaryOrder.Outlet__c);
        System.assertEquals('Primary Order', primaryOrder.Type);
        System.assertEquals('Draft', primaryOrder.Status);

        setPostRequest(payload);
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            orderId,
            (String) ((Map<String, Object>) parseResponse().get('order')).get('id')
        );
        System.assertEquals(1, [SELECT COUNT() FROM Order WHERE DMS_Request_Key__c = 'primary-order-retry-key']);

        setPostRequest(createPayload(
            'create',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            1,
            'secondary-history-key'
        ));
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(201, RestContext.response.statusCode);

        setGetRequest(new Map<String, String>{ 'view' => 'history', 'type' => 'Primary' });
        DMSDistributorOrderResource.getOrders();
        List<Object> orders = (List<Object>) parseResponse().get('orders');
        System.assertEquals(1, orders.size());
        System.assertEquals('Primary', ((Map<String, Object>) orders[0]).get('salesType'));

        setGetRequest(new Map<String, String>{ 'view' => 'history', 'type' => 'Secondary' });
        DMSDistributorOrderResource.getOrders();
        orders = (List<Object>) parseResponse().get('orders');
        System.assertEquals(1, orders.size());
        System.assertEquals('Secondary', ((Map<String, Object>) orders[0]).get('salesType'));

        setGetRequest(new Map<String, String>{ 'orderId' => orderId });
        DMSDistributorOrderResource.getOrders();
        Map<String, Object> orderDetails = (Map<String, Object>) parseResponse().get('order');
        System.assertEquals(orderId, orderDetails.get('id'));
        System.assertEquals('Primary', orderDetails.get('salesType'));
        System.assertEquals('Not Submitted', orderDetails.get('approvalStatus'));
        System.assertEquals(0, ((List<Object>) orderDetails.get('dispatches')).size());
        System.assertEquals(0, ((List<Object>) orderDetails.get('goodsReceipts')).size());
    }

    @IsTest
    static void approvalSubmissionRequiresAnOwnedDraftWithOrderLines() {
        TestData data = createTestData();
        Order incompleteOrder = new Order(
            AccountId = data.distributorId,
            Type = 'Primary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert incompleteOrder;

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => 'Primary',
            'orderId' => incompleteOrder.Id
        });
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> response = parseResponse();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assert(
            String.valueOf(response.get('message')).contains('valid product lines')
        );

        Account otherDistributor = [
            SELECT Id
            FROM Account
            WHERE Name = 'Other Order Distributor'
            LIMIT 1
        ];
        Order otherOrder = new Order(
            AccountId = otherDistributor.Id,
            Type = 'Primary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert otherOrder;

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => 'Primary',
            'orderId' => otherOrder.Id
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(404, RestContext.response.statusCode);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :otherOrder.Id]
        );
    }

    @IsTest
    static void secondaryOrderApprovalSubmissionIsRejected() {
        TestData data = createTestData();
        setPostRequest(createPayload(
            'create',
            'Secondary',
            data.retailerId,
            data.secondaryEntryId,
            1,
            'secondary-no-approval'
        ));
        DMSDistributorOrderResource.postOrder();
        Id orderId = Id.valueOf(
            (String) ((Map<String, Object>) parseResponse().get('order')).get('id')
        );

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => 'Secondary',
            'orderId' => orderId
        });
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> response = parseResponse();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assert(
            String.valueOf(response.get('message')).contains('do not require approval')
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :orderId]
        );
    }

    @IsTest
    static void approvalSubmissionCreatesOneNativeRequestForConfiguredApprover() {
        TestData data = createTestData();
        setPostRequest(createPayload(
            'create',
            'Primary',
            null,
            data.primaryEntryId,
            1,
            'approval-config-order'
        ));
        DMSDistributorOrderResource.postOrder();
        Id orderId = Id.valueOf(
            (String) ((Map<String, Object>) parseResponse().get('order')).get('id')
        );
        User approvalSubmitter = new User(
            Alias = 'dmsappr1',
            Email = 'dms-approval-submitter@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'DMS Approval Submitter',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'dms-approval-' + System.currentTimeMillis() + '@example.invalid'
        );
        insert approvalSubmitter;
        update new Order(Id = orderId, OwnerId = approvalSubmitter.Id);

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => 'Primary',
            'orderId' => orderId
        });
        Test.startTest();
        DMSDistributorOrderResource.postOrder();
        Test.stopTest();

        Map<String, Object> response = parseResponse();
        Map<String, Object> submittedOrder = (Map<String, Object>) response.get('order');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Pending Approval', submittedOrder.get('approvalStatus'));
        System.assertEquals(null, submittedOrder.get('invoiceStatus'));
        System.assertEquals(null, submittedOrder.get('invoiceNumber'));
        System.assertNotEquals(null, submittedOrder.get('approvalSubmittedDate'));
        System.assertNotEquals(null, submittedOrder.get('approvalAssigneeName'));
        System.assertEquals(
            0,
            [SELECT COUNT() FROM DMS_Invoice__c WHERE Secondary_Order__c = :orderId]
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :orderId]
        );

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => 'Primary',
            'orderId' => orderId
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :orderId]
        );
    }

    @IsTest
    static void orderHistoryLoadsOlderPagesWithoutDuplicates() {
        TestData data = createTestData();
        List<Order> testOrders = new List<Order>();
        for (Integer index = 0; index < 101; index++) {
            testOrders.add(new Order(
                AccountId = data.distributorId,
                Type = 'Primary Order',
                EffectiveDate = Date.today(),
                Status = 'Draft',
                Pricebook2Id = Test.getStandardPricebookId()
            ));
        }
        insert testOrders;

        setGetRequest(new Map<String, String>{
            'view' => 'history',
            'type' => 'Primary'
        });
        DMSDistributorOrderResource.getOrders();
        Map<String, Object> firstPage = parseResponse();
        List<Object> firstOrders = (List<Object>) firstPage.get('orders');
        Map<String, Object> cursor = (Map<String, Object>) firstPage.get('nextCursor');
        System.assertEquals(100, firstOrders.size());
        System.assertEquals(true, firstPage.get('hasMore'));
        System.assertNotEquals(null, cursor);

        setGetRequest(new Map<String, String>{
            'view' => 'history',
            'type' => 'Primary',
            'cursorCreatedAt' => String.valueOf(cursor.get('createdAt')),
            'cursorId' => (String) cursor.get('id')
        });
        DMSDistributorOrderResource.getOrders();
        Map<String, Object> secondPage = parseResponse();
        List<Object> secondOrders = (List<Object>) secondPage.get('orders');
        System.assertEquals(1, secondOrders.size());
        System.assertEquals(false, secondPage.get('hasMore'));
        System.assertNotEquals(
            ((Map<String, Object>) firstOrders[99]).get('id'),
            ((Map<String, Object>) secondOrders[0]).get('id')
        );
    }

    @IsTest
    static void secondaryOrderStockValidationDoesNotRequireApproval() {
        TestData data = createTestData();
        Id orderId = createActivatedSecondaryOrder(data, 'stock-validation-order');

        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Unapproved Order Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        Test.startTest();
        setPostRequest(new Map<String, Object>{
            'action' => 'validateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        Test.stopTest();

        Map<String, Object> response = parseResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('available', response.get('status'));
        System.assertEquals(100, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :balance.Id
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
        ]);
    }

    @IsTest
    static void reservationReleaseClosesEachReservationLedgerReference() {
        TestData data = createTestData();
        setPostRequest(createPayload(
            'create',
            'Primary',
            null,
            data.primaryEntryId,
            1,
            'stock-release-order'
        ));
        DMSDistributorOrderResource.postOrder();
        Id orderId = Id.valueOf(
            (String) ((Map<String, Object>) parseResponse().get('order')).get('id')
        );

        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Reservation Release Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 5,
            Reserved_Quantity__c = 5,
            Minimum_Stock_Level__c = 1
        );
        insert balance;
        String firstReference = 'DMS-RES-' + String.valueOf(orderId) + '-first';
        String secondReference = 'DMS-RES-' + String.valueOf(orderId) + '-second';
        insert new List<Inventory_Transaction__c>{
            new Inventory_Transaction__c(
                Inventory__c = balance.Id,
                Transaction_Type__c = 'Stock Reservation',
                Quantity__c = 2,
                Transaction_Date__c = System.now(),
                Reference_Number__c = firstReference,
                Transaction_Description__c = 'First reservation'
            ),
            new Inventory_Transaction__c(
                Inventory__c = balance.Id,
                Transaction_Type__c = 'Stock Reservation',
                Quantity__c = 3,
                Transaction_Date__c = System.now(),
                Reference_Number__c = secondReference,
                Transaction_Description__c = 'Second reservation'
            )
        };

        setPostRequest(new Map<String, Object>{
            'action' => 'releaseStockReservation',
            'orderId' => orderId
        });
        Test.startTest();
        DMSDistributorOrderResource.postOrder();
        Test.stopTest();

        Map<String, Object> response = parseResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('released', response.get('status'));
        Inventory__c releasedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ];
        System.assertEquals(10, releasedBalance.Available_Quantity__c);
        System.assertEquals(0, releasedBalance.Reserved_Quantity__c);

        Map<String, Decimal> releasedByReference = new Map<String, Decimal>();
        for (Inventory_Transaction__c release : [
            SELECT Reference_Number__c, Quantity__c
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
              AND Transaction_Type__c = 'Stock Release'
        ]) {
            releasedByReference.put(release.Reference_Number__c, release.Quantity__c);
        }
        System.assertEquals(2, releasedByReference.size());
        System.assertEquals(Decimal.valueOf('2'), releasedByReference.get(firstReference));
        System.assertEquals(Decimal.valueOf('3'), releasedByReference.get(secondReference));
    }

    @IsTest
    static void secondaryOrderCanValidateAndReserveStockIdempotently() {
        TestData data = createTestData();
        Id orderId = createActivatedSecondaryOrder(data, 'stock-reservation-order');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Stock Reservation Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 5,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        Test.startTest();
        setPostRequest(new Map<String, Object>{
            'action' => 'validateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        Map<String, Object> validation = parseResponse();
        List<Object> lines = (List<Object>) validation.get('lines');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('available', validation.get('status'));
        System.assertEquals(Decimal.valueOf('60'), ((Map<String, Object>) lines[0]).get('requiredQuantity'));

        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('allocated', parseResponse().get('status'));
        System.assertEquals(100, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :balance.Id
        ].Available_Quantity__c);

        Map<String, Object> reservation = new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'reserve-once'
        };
        setPostRequest(reservation);
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('reserved', parseResponse().get('status'));
        System.assertEquals('Reserved', [
            SELECT DMS_Allocation_Status__c FROM Order WHERE Id = :orderId
        ].DMS_Allocation_Status__c);

        Inventory__c reservedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ];
        System.assertEquals(40, reservedBalance.Available_Quantity__c);
        System.assertEquals(65, reservedBalance.Reserved_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
              AND Transaction_Type__c = 'Stock Reservation'
        ]);

        setPostRequest(reservation);
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, parseResponse().get('alreadyProcessed'));
        System.assertEquals(40, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :balance.Id
        ].Available_Quantity__c);
        Test.stopTest();
    }

    @IsTest
    static void primaryOrdersCannotBeValidatedOrReservedForOutboundFulfillment() {
        TestData data = createTestData();
        Id orderId = createApprovedPrimaryOrder(data, 'primary-order-no-outbound-stock-check');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Primary Receipt Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        for (String action : new List<String>{
            'findWarehouses', 'allocateStock', 'validateStock', 'reserveStock'
        }) {
            Map<String, Object> payload = new Map<String, Object>{
                'action' => action,
                'orderId' => orderId,
                'warehouseId' => warehouse.Id,
                'idempotencyKey' => 'primary-order-rejected-' + action
            };
            setPostRequest(payload);
            DMSDistributorOrderResource.postOrder();
            Map<String, Object> response = parseResponse();
            System.assertEquals(409, RestContext.response.statusCode, action);
            System.assert(
                String.valueOf(response.get('message')).contains('Secondary Orders'),
                action
            );
        }

        Inventory__c unchangedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ];
        System.assertEquals(100, unchangedBalance.Available_Quantity__c);
        System.assertEquals(0, unchangedBalance.Reserved_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM DMS_Order_Allocation__c
            WHERE Order__c = :orderId
        ]);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Inventory__c = :balance.Id
              AND Transaction_Type__c IN ('Stock Reservation', 'Stock Release')
        ]);
    }

    @IsTest
    static void secondaryMultiProductOrderCanReserveEveryInventoryBalance() {
        TestData data = createTestData();
        Id secondPricebookEntryId = createSecondSecondaryEntry();
        Id orderId = createActivatedSecondaryOrderWithSecondProduct(
            data,
            'multi-product-reservation-order',
            secondPricebookEntryId
        );
        Id secondProductId = [
            SELECT Product2Id
            FROM PricebookEntry
            WHERE Id = :secondPricebookEntryId
        ].Product2Id;
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Multi Product Reservation Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        insert new List<Inventory__c>{
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = data.productId,
                Available_Quantity__c = 100,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            ),
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = secondProductId,
                Available_Quantity__c = 10,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            )
        };

        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);

        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'multi-product-reserve'
        });
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> response = parseResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(2, ((List<Object>) response.get('lines')).size());
        Map<Id, Inventory__c> inventoryByProduct = new Map<Id, Inventory__c>();
        for (Inventory__c inventory : [
            SELECT Product__c, Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouse.Id
        ]) {
            inventoryByProduct.put(inventory.Product__c, inventory);
        }
        System.assertEquals(40, inventoryByProduct.get(data.productId).Available_Quantity__c);
        System.assertEquals(60, inventoryByProduct.get(data.productId).Reserved_Quantity__c);
        System.assertEquals(9, inventoryByProduct.get(secondProductId).Available_Quantity__c);
        System.assertEquals(1, inventoryByProduct.get(secondProductId).Reserved_Quantity__c);
        System.assertEquals(100,
            inventoryByProduct.get(data.productId).Available_Quantity__c
            + inventoryByProduct.get(data.productId).Reserved_Quantity__c,
            'Reservation must not deduct physical on-hand stock.'
        );
        String reservationPattern = 'DMS-RES-' + String.valueOf(orderId) + '-%';
        System.assertEquals(2, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :reservationPattern
              AND Transaction_Type__c = 'Stock Reservation'
        ]);
    }

    @IsTest
    static void multiProductShortageLeavesEveryInventoryBalanceUnchanged() {
        TestData data = createTestData();
        Id secondPricebookEntryId = createSecondSecondaryEntry();
        Id orderId = createActivatedSecondaryOrderWithSecondProduct(
            data,
            'multi-product-shortage-order',
            secondPricebookEntryId
        );
        Id secondProductId = [
            SELECT Product2Id
            FROM PricebookEntry
            WHERE Id = :secondPricebookEntryId
        ].Product2Id;
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Multi Product Shortage Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        List<Inventory__c> balances = new List<Inventory__c>{
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = data.productId,
                Available_Quantity__c = 100,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            ),
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = secondProductId,
                Available_Quantity__c = 0,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            )
        };
        insert balances;
        update new Order(
            Id = orderId,
            DMS_Fulfillment_Warehouse__c = warehouse.Id,
            DMS_Allocation_Status__c = 'Allocated'
        );
        insert new List<DMS_Order_Allocation__c>{
            new DMS_Order_Allocation__c(
                Order__c = orderId,
                Product__c = data.productId,
                Warehouse__c = warehouse.Id,
                Allocated_Quantity__c = 60,
                Allocation_Key__c = String.valueOf(orderId) + ':' + String.valueOf(data.productId),
                Allocation_Status__c = 'Allocated'
            ),
            new DMS_Order_Allocation__c(
                Order__c = orderId,
                Product__c = secondProductId,
                Warehouse__c = warehouse.Id,
                Allocated_Quantity__c = 1,
                Allocation_Key__c = String.valueOf(orderId) + ':' + String.valueOf(secondProductId),
                Allocation_Status__c = 'Allocated'
            )
        };

        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'multi-product-shortage'
        });
        DMSDistributorOrderResource.postOrder();

        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(100, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :balances[0].Id
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balances[0].Id
        ].Reserved_Quantity__c);
        String reservationPattern = 'DMS-RES-' + String.valueOf(orderId) + '-%';
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :reservationPattern
        ]);
    }

    @IsTest
    static void competingReservationsRecheckLockedInventoryBalances() {
        TestData data = createTestData();
        Id firstOrderId = createActivatedSecondaryOrder(data, 'competing-reserve-first');
        Id secondOrderId = createActivatedSecondaryOrder(data, 'competing-reserve-second');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Competing Reservation Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 120,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        Test.startTest();
        for (Id orderId : new List<Id>{firstOrderId, secondOrderId}) {
            setPostRequest(new Map<String, Object>{
                'action' => 'allocateStock',
                'orderId' => orderId,
                'warehouseId' => warehouse.Id
            });
            DMSDistributorOrderResource.postOrder();
            System.assertEquals(200, RestContext.response.statusCode);
        }
        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => firstOrderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'competing-reserve-first-key'
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);

        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => secondOrderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'competing-reserve-second-key'
        });
        DMSDistributorOrderResource.postOrder();

        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Available_Quantity__c);
        System.assertEquals(120, [
            SELECT Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Reserved_Quantity__c);
        String secondReservationPattern = 'DMS-RES-' + String.valueOf(secondOrderId) + '-%';
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c LIKE :secondReservationPattern
              AND Transaction_Type__c = 'Stock Reservation'
        ]);
    }

    @IsTest
    static void leavingActivatedStatusAutomaticallyReleasesItsReservationOnce() {
        TestData data = createTestData();
        Id orderId = createActivatedSecondaryOrder(data, 'cancelled-reservation-order');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Cancellation Reservation Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert balance;
        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'cancelled-order-reserve'
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);

        update new Order(Id = orderId, Status = 'Draft');
        String reservationPattern = 'DMS-RES-' + String.valueOf(orderId) + '-%';

        Inventory__c releasedBalance = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ];
        System.assertEquals(100, releasedBalance.Available_Quantity__c);
        System.assertEquals(0, releasedBalance.Reserved_Quantity__c);
        System.assertEquals('Not Allocated', [
            SELECT DMS_Allocation_Status__c
            FROM Order
            WHERE Id = :orderId
        ].DMS_Allocation_Status__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Transaction_Type__c = 'Stock Release'
              AND Reference_Number__c LIKE :reservationPattern
        ]);
        System.assertEquals('Released', [
            SELECT Allocation_Status__c
            FROM DMS_Order_Allocation__c
            WHERE Order__c = :orderId
        ].Allocation_Status__c);

        update new Order(Id = orderId, Status = 'Draft');
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Transaction_Type__c = 'Stock Release'
              AND Reference_Number__c LIKE :reservationPattern
        ]);

    }

    @IsTest
    static void approvedOrderReportsShortagesAndRejectsForeignWarehouse() {
        TestData data = createTestData();
        Id orderId = createActivatedSecondaryOrder(data, 'stock-shortage-order');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Shortage Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Account otherDistributor = [
            SELECT Id FROM Account WHERE Name = 'Other Order Distributor' LIMIT 1
        ];
        Warehouse__c foreignWarehouse = new Warehouse__c(
            Name = 'Foreign Fulfillment Warehouse',
            Distributor__c = otherDistributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{warehouse, foreignWarehouse};
        insert new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 10,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );

        setPostRequest(new Map<String, Object>{
            'action' => 'validateStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        Map<String, Object> shortage = parseResponse();
        List<Object> lines = (List<Object>) shortage.get('lines');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('insufficient', shortage.get('status'));
        System.assertEquals(Decimal.valueOf('50'), ((Map<String, Object>) lines[0]).get('shortageQuantity'));

        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => orderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'shortage-no-reserve'
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(10, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Warehouse__c = :warehouse.Id AND Product__c = :data.productId
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Transaction_Type__c = 'Stock Reservation'
              AND Inventory__r.Warehouse__c = :warehouse.Id
        ]);

        setPostRequest(new Map<String, Object>{
            'action' => 'validateStock',
            'orderId' => orderId,
            'warehouseId' => foreignWarehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(409, RestContext.response.statusCode);
    }

    @IsTest
    static void warehouseDiscoveryAggregatesOrderLinesAndRanksSufficientWarehousesFirst() {
        TestData data = createTestData();
        Id orderId = createActivatedSecondaryOrder(
            data,
            'warehouse-discovery-order',
            true
        );
        Warehouse__c suitableWarehouse = new Warehouse__c(
            Name = 'A Suitable Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c insufficientWarehouse = new Warehouse__c(
            Name = 'Z Insufficient Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{suitableWarehouse, insufficientWarehouse};
        insert new List<Inventory__c>{
            new Inventory__c(
                Warehouse__c = suitableWarehouse.Id,
                Product__c = data.productId,
                Available_Quantity__c = 120,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            ),
            new Inventory__c(
                Warehouse__c = insufficientWarehouse.Id,
                Product__c = data.productId,
                Available_Quantity__c = 119,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 1
            )
        };

        setPostRequest(new Map<String, Object>{
            'action' => 'findWarehouses',
            'orderId' => orderId
        });
        DMSDistributorOrderResource.postOrder();

        Map<String, Object> response = parseResponse();
        List<Object> candidates = (List<Object>) response.get('candidates');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('candidatesFound', response.get('status'));
        System.assertEquals(2, candidates.size());
        Map<String, Object> suitable = (Map<String, Object>) candidates[0];
        Map<String, Object> insufficient = (Map<String, Object>) candidates[1];
        System.assertEquals(String.valueOf(suitableWarehouse.Id), suitable.get('warehouseId'));
        System.assertEquals(true, suitable.get('canAllocate'));
        System.assertEquals('Not Allocated', suitable.get('allocationStatus'));
        List<Object> aggregatedLines = (List<Object>) suitable.get('lines');
        System.assertEquals(1, aggregatedLines.size(), 'Duplicate product lines should be aggregated.');
        System.assertEquals(
            Decimal.valueOf('120'),
            ((Map<String, Object>) aggregatedLines[0]).get('requiredQuantity')
        );
        System.assertEquals(String.valueOf(insufficientWarehouse.Id), insufficient.get('warehouseId'));
        System.assertEquals(false, insufficient.get('canAllocate'));
        System.assertEquals(
            Decimal.valueOf('1'),
            ((Map<String, Object>) ((List<Object>) insufficient.get('lines'))[0])
                .get('shortageQuantity')
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Inventory_Transaction__c
             WHERE Transaction_Type__c = 'Stock Reservation']
        );

        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => orderId,
            'warehouseId' => suitableWarehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        Map<String, Object> allocationResult = parseResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('allocated', allocationResult.get('status'));
        System.assertEquals(1, ((List<Object>) allocationResult.get('allocations')).size());
        System.assertEquals(120, [
            SELECT Available_Quantity__c FROM Inventory__c
            WHERE Warehouse__c = :suitableWarehouse.Id AND Product__c = :data.productId
        ].Available_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT() FROM DMS_Order_Allocation__c
            WHERE Order__c = :orderId AND Allocation_Status__c = 'Allocated'
        ]);

        setGetRequest(new Map<String, String>{'view' => 'history', 'type' => 'Secondary'});
        DMSDistributorOrderResource.getOrders();
        Map<String, Object> history = parseResponse();
        Map<String, Object> orderSummary;
        for (Object orderValue : (List<Object>) history.get('orders')) {
            Map<String, Object> candidateOrder = (Map<String, Object>) orderValue;
            if (candidateOrder.get('id') == String.valueOf(orderId)) {
                orderSummary = candidateOrder;
                break;
            }
        }
        System.assertNotEquals(null, orderSummary);
        System.assertEquals('Activated', orderSummary.get('status'));
        System.assertEquals('Not Submitted', orderSummary.get('approvalStatus'));
        System.assertEquals('Allocated', orderSummary.get('allocationStatus'));
        System.assertEquals(String.valueOf(suitableWarehouse.Id), orderSummary.get('fulfillmentWarehouseId'));
        System.assertEquals(1, ((List<Object>) orderSummary.get('allocationLines')).size());
        System.assertEquals(null, orderSummary.get('approvalDate'));
        System.assertEquals(null, orderSummary.get('approvedBy'));
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :orderId],
            'Secondary fulfillment does not create an order approval request.'
        );
    }

    @IsTest
    static void competingOrderReservationsCannotAllocateTheSameStockTwice() {
        TestData data = createTestData();
        Id firstOrderId = createActivatedSecondaryOrder(data, 'competing-order-first');
        Id secondOrderId = createActivatedSecondaryOrder(data, 'competing-order-second');
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Competing Allocation Warehouse',
            Distributor__c = data.distributorId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Inventory__c balance = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = data.productId,
            Available_Quantity__c = 100,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert balance;

        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => firstOrderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);

        setPostRequest(new Map<String, Object>{
            'action' => 'allocateStock',
            'orderId' => secondOrderId,
            'warehouseId' => warehouse.Id
        });
        DMSDistributorOrderResource.postOrder();
        Map<String, Object> rejectedReservation = parseResponse();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(false, rejectedReservation.get('canAllocate'));
        System.assertEquals(100, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Reserved_Quantity__c);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM DMS_Order_Allocation__c
             WHERE Warehouse__c = :warehouse.Id
               AND Allocation_Status__c = 'Allocated']
        );

        setPostRequest(new Map<String, Object>{
            'action' => 'reserveStock',
            'orderId' => firstOrderId,
            'warehouseId' => warehouse.Id,
            'idempotencyKey' => 'competing-first'
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(40, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :balance.Id
        ].Available_Quantity__c);
    }

    private static Id createApprovedPrimaryOrder(TestData data, String requestKey) {
        return createApprovedPrimaryOrder(data, requestKey, false);
    }

    private static Id createApprovedPrimaryOrder(
        TestData data,
        String requestKey,
        Boolean addDuplicateLine
    ) {
        setPostRequest(createPayload(
            'create',
            'Primary',
            null,
            data.primaryEntryId,
            1,
            requestKey
        ));
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(201, RestContext.response.statusCode);
        Id orderId = Id.valueOf(
            (String) ((Map<String, Object>) parseResponse().get('order')).get('id')
        );
        if (addDuplicateLine) {
            OrderItem originalLine = [
                SELECT PricebookEntryId, Quantity, UnitPrice, DMS_List_Price__c,
                       Paid_Quantity__c, Free_Quantity__c, Unit_of_Measure__c,
                       Unit_Conversion_Factor__c, DMS_Tax_Rate__c, DMS_Tax_Amount__c
                FROM OrderItem
                WHERE OrderId = :orderId
                LIMIT 1
            ];
            insert new OrderItem(
                OrderId = orderId,
                PricebookEntryId = originalLine.PricebookEntryId,
                Quantity = originalLine.Quantity,
                UnitPrice = originalLine.UnitPrice,
                DMS_List_Price__c = originalLine.DMS_List_Price__c,
                Paid_Quantity__c = originalLine.Paid_Quantity__c,
                Free_Quantity__c = originalLine.Free_Quantity__c,
                Unit_of_Measure__c = originalLine.Unit_of_Measure__c,
                Unit_Conversion_Factor__c = originalLine.Unit_Conversion_Factor__c,
                DMS_Tax_Rate__c = originalLine.DMS_Tax_Rate__c,
                DMS_Tax_Amount__c = originalLine.DMS_Tax_Amount__c
            );
        }

        return approvePrimaryOrder(orderId);
    }

    private static Id createActivatedSecondaryOrder(TestData data, String requestKey) {
        return createActivatedSecondaryOrder(data, requestKey, false);
    }

    private static Id createActivatedSecondaryOrder(
        TestData data,
        String requestKey,
        Boolean addDuplicateLine
    ) {
        PricebookEntry entry = [
            SELECT Pricebook2Id
            FROM PricebookEntry
            WHERE Id = :data.secondaryEntryId
        ];
        Order salesOrder = new Order(
            AccountId = data.distributorId,
            Outlet__c = data.retailerId,
            Type = 'Secondary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = entry.Pricebook2Id,
            DMS_Request_Key__c = requestKey
        );
        insert salesOrder;
        List<OrderItem> lines = new List<OrderItem>{
            buildTestOrderItem(salesOrder.Id, data.secondaryEntryId, 60)
        };
        if (addDuplicateLine) {
            lines.add(buildTestOrderItem(salesOrder.Id, data.secondaryEntryId, 60));
        }
        insert lines;
        salesOrder.Status = 'Activated';
        update salesOrder;
        return salesOrder.Id;
    }

    private static Id createActivatedSecondaryOrderWithSecondProduct(
        TestData data,
        String requestKey,
        Id secondPricebookEntryId
    ) {
        PricebookEntry entry = [
            SELECT Pricebook2Id
            FROM PricebookEntry
            WHERE Id = :data.secondaryEntryId
        ];
        Order salesOrder = new Order(
            AccountId = data.distributorId,
            Outlet__c = data.retailerId,
            Type = 'Secondary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = entry.Pricebook2Id,
            DMS_Request_Key__c = requestKey
        );
        insert salesOrder;
        insert new List<OrderItem>{
            buildTestOrderItem(salesOrder.Id, data.secondaryEntryId, 60),
            buildTestOrderItem(salesOrder.Id, secondPricebookEntryId, 1)
        };
        salesOrder.Status = 'Activated';
        update salesOrder;
        return salesOrder.Id;
    }

    private static OrderItem buildTestOrderItem(
        Id orderId,
        Id pricebookEntryId,
        Decimal quantity
    ) {
        PricebookEntry entry = [
            SELECT Id, UnitPrice, Unit_of_Measure__c, Unit_Conversion_Factor__c,
                   Product2.DMS_Tax_Rate__c
            FROM PricebookEntry
            WHERE Id = :pricebookEntryId
        ];
        Decimal taxRate = entry.Product2.DMS_Tax_Rate__c == null
            ? 0
            : entry.Product2.DMS_Tax_Rate__c;
        return new OrderItem(
            OrderId = orderId,
            PricebookEntryId = entry.Id,
            Quantity = quantity,
            UnitPrice = entry.UnitPrice,
            DMS_List_Price__c = entry.UnitPrice,
            Paid_Quantity__c = quantity,
            Free_Quantity__c = 0,
            Unit_of_Measure__c = entry.Unit_of_Measure__c,
            Unit_Conversion_Factor__c = entry.Unit_Conversion_Factor__c,
            DMS_Tax_Rate__c = taxRate,
            DMS_Tax_Amount__c = (entry.UnitPrice * quantity * taxRate / 100).setScale(2)
        );
    }

    private static Id approvePrimaryOrder(Id orderId) {
        Order orderToApprove = [SELECT Type FROM Order WHERE Id = :orderId];
        User owner = new User(
            Alias = 'dmsful',
            Email = 'dms-fulfillment-owner@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'DMS Fulfillment Owner',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'dms-fulfillment-' + System.currentTimeMillis() + '@example.invalid'
        );
        insert owner;
        update new Order(Id = orderId, OwnerId = owner.Id);
        createDraftInvoiceForOrder(orderId);

        setPostRequest(new Map<String, Object>{
            'action' => 'submitForApproval',
            'salesType' => orderToApprove.Type == 'Primary Order'
                ? 'Primary'
                : 'Secondary',
            'orderId' => orderId
        });
        DMSDistributorOrderResource.postOrder();
        System.assertEquals(200, RestContext.response.statusCode);

        ProcessInstanceWorkitem workItem = [
            SELECT Id
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :orderId
            LIMIT 1
        ];
        DMS_Order_Approval_Config__mdt approvalConfig =
            DMS_Order_Approval_Config__mdt.getInstance('Default');
        User approver = [
            SELECT Id
            FROM User
            WHERE Username = :approvalConfig.Approver_Username__c
            LIMIT 1
        ];
        Approval.ProcessWorkitemRequest approvalRequest =
            new Approval.ProcessWorkitemRequest();
        approvalRequest.setWorkitemId(workItem.Id);
        approvalRequest.setAction('Approve');
        Approval.ProcessResult approvalResult;
        System.runAs(approver) {
            approvalResult = Approval.process(approvalRequest);
        }
        System.assertEquals(true, approvalResult.isSuccess());
        System.assertEquals(
            'Activated',
            [SELECT Status FROM Order WHERE Id = :orderId].Status,
            'The approval final action must activate approved orders.'
        );
        return orderId;
    }

    private static void createDraftInvoiceForOrder(Id orderId) {
        Order salesOrder = [
            SELECT Id, AccountId, Outlet__c, Type
            FROM Order
            WHERE Id = :orderId
            LIMIT 1
        ];
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Approval Invoice Warehouse ' + String.valueOf(orderId).right(6),
            Distributor__c = salesOrder.AccountId,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;

        List<OrderItem> orderItems = [
            SELECT Id, Product2Id, Product2.Name, Product2.DMS_Tax_Rate__c,
                   Quantity, UnitPrice, ListPrice, DMS_List_Price__c,
                   Unit_of_Measure__c, DMS_Tax_Rate__c, DMS_Tax_Amount__c
            FROM OrderItem
            WHERE OrderId = :salesOrder.Id
            ORDER BY CreatedDate, Id
        ];
        Decimal subtotal = 0;
        Decimal discount = 0;
        Decimal taxable = 0;
        Decimal tax = 0;
        List<DMS_Invoice_Line__c> invoiceLines = new List<DMS_Invoice_Line__c>();
        for (OrderItem item : orderItems) {
            Decimal listPrice = item.DMS_List_Price__c == null
                ? item.ListPrice
                : item.DMS_List_Price__c;
            Decimal grossAmount = (listPrice * item.Quantity).setScale(2);
            Decimal lineTaxable = (item.UnitPrice * item.Quantity).setScale(2);
            Decimal lineDiscount = (grossAmount - lineTaxable).setScale(2);
            Decimal taxRate = item.DMS_Tax_Rate__c == null
                ? (item.Product2.DMS_Tax_Rate__c == null ? 0 : item.Product2.DMS_Tax_Rate__c)
                : item.DMS_Tax_Rate__c;
            Decimal lineTax = item.DMS_Tax_Amount__c == null
                ? (lineTaxable * taxRate / 100).setScale(2)
                : item.DMS_Tax_Amount__c.setScale(2);
            subtotal += grossAmount;
            discount += lineDiscount;
            taxable += lineTaxable;
            tax += lineTax;
            invoiceLines.add(new DMS_Invoice_Line__c(
                Order_Line_Item__c = item.Id,
                Product__c = item.Product2Id,
                Quantity__c = item.Quantity,
                Unit_Price__c = item.UnitPrice,
                Gross_Amount__c = grossAmount,
                Discount_Amount__c = lineDiscount,
                Taxable_Amount__c = lineTaxable,
                Tax_Rate__c = taxRate,
                Tax_Amount__c = lineTax,
                Line_Total__c = lineTaxable + lineTax,
                Unit_of_Measure__c = item.Unit_of_Measure__c
            ));
        }
        Decimal invoiceTotal = (taxable + tax).setScale(2);
        DMS_Invoice__c invoice = new DMS_Invoice__c(
            Invoice_Date__c = Date.today(),
            Distributor__c = salesOrder.AccountId,
            Retailer__c = salesOrder.Type == 'Primary Order'
                ? salesOrder.AccountId
                : salesOrder.Outlet__c,
            Secondary_Order__c = salesOrder.Id,
            Warehouse__c = warehouse.Id,
            Status__c = 'Draft',
            Subtotal__c = subtotal.setScale(2),
            Total_Discount__c = discount.setScale(2),
            Taxable_Amount__c = taxable.setScale(2),
            Tax_Amount__c = tax.setScale(2),
            Invoice_Total__c = invoiceTotal,
            Credited_Amount__c = 0,
            Amount_Paid__c = 0,
            Balance_Due__c = invoiceTotal,
            Stock_Deduction_Status__c = 'Pending Dispatch',
            Request_Key__c = 'approval-' + String.valueOf(orderId)
        );
        insert invoice;
        for (DMS_Invoice_Line__c invoiceLine : invoiceLines) {
            invoiceLine.Invoice__c = invoice.Id;
        }
        insert invoiceLines;
    }

    private static Scheme_Product__c createSchemeRule(
        Id productId,
        String salesType,
        String schemeName,
        Decimal minimumQuantity,
        String minimumUnit,
        Decimal freeQuantity,
        String freeUnit,
        Decimal priority,
        Date startDate,
        Date endDate
    ) {
        Scheme__c scheme = new Scheme__c(
            Scheme_Name__c = schemeName,
            Scheme_Type__c = 'Free Product',
            Sales_Type__c = salesType,
            Start_Date__c = startDate,
            End_Date__c = endDate,
            Active__c = true,
            Status__c = 'Active'
        );
        insert scheme;

        Scheme_Product__c schemeProduct = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product__c = productId,
            Minimum_Quantity__c = minimumQuantity,
            Minimum_Unit__c = minimumUnit,
            Free_Quantity__c = freeQuantity,
            Free_Unit__c = freeUnit,
            Priority__c = priority,
            Active__c = true
        );
        insert schemeProduct;
        return schemeProduct;
    }

    private static Map<String, Object> createPayload(
        String action,
        String salesType,
        Id retailerId,
        Id entryId,
        Decimal quantity,
        String requestKey
    ) {
        Map<String, Object> payload = new Map<String, Object>{
            'action' => action,
            'salesType' => salesType,
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'pricebookEntryId' => entryId,
                    'quantity' => quantity
                }
            }
        };
        if (retailerId != null) {
            payload.put('retailerId', retailerId);
        }
        if (requestKey != null) {
            payload.put('requestKey', requestKey);
        }
        return payload;
    }

    private static Id createSecondSecondaryEntry() {
        Product2 product = new Product2(
            Name = 'Second Reservation Test Product',
            ProductCode = 'ORDER-TEST-SECOND',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece',
            DMS_Tax_Rate__c = 10
        );
        insert product;
        Id standardPricebookId = Test.getStandardPricebookId();
        Pricebook2 secondaryPricebook = [
            SELECT Id
            FROM Pricebook2
            WHERE Sales_Type__c = 'Secondary'
            LIMIT 1
        ];
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = product.Id,
                UnitPrice = 20,
                IsActive = true,
                Unit_of_Measure__c = 'Piece',
                Unit_Conversion_Factor__c = 1
            ),
            new PricebookEntry(
                Pricebook2Id = secondaryPricebook.Id,
                Product2Id = product.Id,
                UnitPrice = 1200,
                IsActive = true,
                Unit_of_Measure__c = 'Piece',
                Unit_Conversion_Factor__c = 1
            )
        };
        return [
            SELECT Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :secondaryPricebook.Id
              AND Product2Id = :product.Id
            LIMIT 1
        ].Id;
    }

    private static TestData createTestData() {
        Account distributor = new Account(
            Name = 'Order Test Distributor',
            Email__c = 'orders@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            DMS_Session_Token_Hash__c = hashToken(TOKEN),
            DMS_Session_Expires_At__c = System.now().addHours(1)
        );
        insert distributor;
        Account otherDistributor = new Account(
            Name = 'Other Order Distributor',
            Email__c = 'other-orders@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active'
        );
        insert otherDistributor;
        Account retailer = new Account(
            Name = 'Authorized Order Retailer',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributor.Id
        );
        Account otherRetailer = new Account(
            Name = 'Unauthorized Order Retailer',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = otherDistributor.Id
        );
        insert new List<Account>{ retailer, otherRetailer };

        Product2 product = new Product2(
            Name = 'Order Test Product',
            ProductCode = 'ORDER-TEST',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece',
            DMS_Tax_Rate__c = 10
        );
        insert product;

        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);
        insert new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 20,
            IsActive = true,
            Unit_of_Measure__c = 'Piece',
            Unit_Conversion_Factor__c = 1
        );

        Pricebook2 primaryPricebook = new Pricebook2(
            Name = 'DMS Primary Test Pricebook',
            IsActive = true,
            Sales_Type__c = 'Primary'
        );
        Pricebook2 secondaryPricebook = new Pricebook2(
            Name = 'DMS Secondary Test Pricebook',
            IsActive = true,
            Sales_Type__c = 'Secondary'
        );
        insert new List<Pricebook2>{ primaryPricebook, secondaryPricebook };
        PricebookEntry primaryEntry = new PricebookEntry(
            Pricebook2Id = primaryPricebook.Id,
            Product2Id = product.Id,
            UnitPrice = 1200,
            IsActive = true,
            Unit_of_Measure__c = 'Case',
            Unit_Conversion_Factor__c = 60
        );
        PricebookEntry secondaryEntry = new PricebookEntry(
            Pricebook2Id = secondaryPricebook.Id,
            Product2Id = product.Id,
            UnitPrice = 20,
            IsActive = true,
            Unit_of_Measure__c = 'Piece',
            Unit_Conversion_Factor__c = 1
        );
        insert new List<PricebookEntry>{ primaryEntry, secondaryEntry };
        return new TestData(
            product.Id,
            distributor.Id,
            retailer.Id,
            otherRetailer.Id,
            primaryEntry.Id,
            secondaryEntry.Id
        );
    }

    private static void setPostRequest(Map<String, Object> payload) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = 'POST';
        RestContext.request.headers.put('X-DMS-Session', TOKEN);
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(payload));
        RestContext.response = new RestResponse();
    }

    private static void setGetRequest(Map<String, String> parameters) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = 'GET';
        RestContext.request.headers.put('X-DMS-Session', TOKEN);
        RestContext.request.params.putAll(parameters);
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> parseResponse() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
    }

    private static String hashToken(String token) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
    }

    private class TestData {
        Id productId;
        Id distributorId;
        Id retailerId;
        Id otherRetailerId;
        Id primaryEntryId;
        Id secondaryEntryId;

        TestData(
            Id product,
            Id distributor,
            Id retailer,
            Id otherRetailer,
            Id primaryEntry,
            Id secondaryEntry
        ) {
            productId = product;
            distributorId = distributor;
            retailerId = retailer;
            otherRetailerId = otherRetailer;
            primaryEntryId = primaryEntry;
            secondaryEntryId = secondaryEntry;
        }
    }
}
