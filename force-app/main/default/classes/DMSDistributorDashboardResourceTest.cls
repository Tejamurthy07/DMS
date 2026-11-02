@IsTest
private class DMSDistributorDashboardResourceTest {
    private static final String DISTRIBUTOR_A_TOKEN =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    private static final String DISTRIBUTOR_B_TOKEN =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    @IsTest
    static void dashboardOnlyReturnsRecordsForTokenDistributor() {
        Account distributorA = createDistributor('Dashboard Distributor A', DISTRIBUTOR_A_TOKEN);
        Account distributorB = createDistributor('Dashboard Distributor B', DISTRIBUTOR_B_TOKEN);
        Account retailerA = new Account(
            Name = 'Dashboard Distributor A Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributorA.Id
        );
        insert retailerA;

        insert new List<Order>{
            new Order(
                AccountId = distributorA.Id,
                Type = 'Primary Order',
                EffectiveDate = Date.today(),
                Status = 'Draft',
                Pricebook2Id = Test.getStandardPricebookId()
            ),
            new Order(
                AccountId = distributorA.Id,
                Outlet__c = retailerA.Id,
                Type = 'Secondary Order',
                EffectiveDate = Date.today(),
                Status = 'Draft',
                Pricebook2Id = Test.getStandardPricebookId()
            ),
            new Order(
                AccountId = distributorB.Id,
                Type = 'Secondary Order',
                EffectiveDate = Date.today(),
                Status = 'Draft',
                Pricebook2Id = Test.getStandardPricebookId()
            )
        };

        setRequest(DISTRIBUTOR_A_TOKEN);
        Test.startTest();
        DMSDistributorDashboardResource.getDashboard();
        Test.stopTest();

        Map<String, Object> dashboard = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Map<String, Object> distributor = (Map<String, Object>) dashboard.get('distributor');
        List<Object> recentOrders = (List<Object>) dashboard.get('recentOrders');
        Map<String, Object> summary = (Map<String, Object>) dashboard.get('summary');

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Dashboard Distributor A', distributor.get('name'));
        System.assertEquals(2, recentOrders.size());
        System.assertEquals(2, summary.get('totalOrders'));
        System.assertEquals(1, summary.get('primaryOrders'));
        System.assertEquals(1, summary.get('secondaryOrders'));
        System.assertEquals(1, summary.get('pendingPrimaryOrders'));
        System.assertEquals(1, summary.get('pendingSecondaryOrders'));
        System.assertEquals(1, summary.get('draftPrimaryOrders'));
        System.assertEquals(1, summary.get('draftSecondaryOrders'));
        System.assertEquals(0, summary.get('invoiceRecordCount'));
        System.assertEquals(0, summary.get('availableInventoryPositionCount'));
        System.assertEquals(0, summary.get('lowStockProductCount'));
        System.assertEquals(0, summary.get('lowStockInventoryPositionCount'));
        System.assertEquals(0, summary.get('pendingReturnCount'));
        Set<String> returnedSalesTypes = new Set<String>();
        for (Object recentOrder : recentOrders) {
            returnedSalesTypes.add(
                (String) ((Map<String, Object>) recentOrder).get('salesType')
            );
        }
        System.assertEquals(new Set<String>{ 'Primary', 'Secondary' }, returnedSalesTypes);
    }

    @IsTest
    static void dashboardInventorySummaryUsesQuantitiesAndDistributorWarehouses() {
        Account distributor = createDistributor(
            'Inventory Summary Distributor',
            DISTRIBUTOR_A_TOKEN
        );
        Account otherDistributor = createDistributor(
            'Other Inventory Summary Distributor',
            DISTRIBUTOR_B_TOKEN
        );
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Inventory Summary Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c secondWarehouse = new Warehouse__c(
            Name = 'Inventory Summary Second Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c otherWarehouse = new Warehouse__c(
            Name = 'Other Inventory Summary Warehouse',
            Distributor__c = otherDistributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{ warehouse, secondWarehouse, otherWarehouse };

        Product2 inStockProduct = new Product2(
            Name = 'Inventory Summary In Stock Product',
            IsActive = true
        );
        Product2 lowStockProduct = new Product2(
            Name = 'Inventory Summary Low Stock Product',
            IsActive = true
        );
        Product2 outOfStockProduct = new Product2(
            Name = 'Inventory Summary Out of Stock Product',
            IsActive = true
        );
        insert new List<Product2>{ inStockProduct, lowStockProduct, outOfStockProduct };
        insert new List<Inventory__c>{
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = inStockProduct.Id,
                Available_Quantity__c = 15,
                Minimum_Stock_Level__c = 10
            ),
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = lowStockProduct.Id,
                Available_Quantity__c = 5,
                Minimum_Stock_Level__c = 10
            ),
            new Inventory__c(
                Warehouse__c = secondWarehouse.Id,
                Product__c = lowStockProduct.Id,
                Available_Quantity__c = 3,
                Minimum_Stock_Level__c = 10
            ),
            new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = outOfStockProduct.Id,
                Available_Quantity__c = 0,
                Minimum_Stock_Level__c = 10
            ),
            new Inventory__c(
                Warehouse__c = otherWarehouse.Id,
                Product__c = inStockProduct.Id,
                Available_Quantity__c = 100,
                Minimum_Stock_Level__c = 10
            )
        };

        setRequest(DISTRIBUTOR_A_TOKEN);
        Test.startTest();
        DMSDistributorDashboardResource.getDashboard();
        Test.stopTest();

        Map<String, Object> dashboard = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Map<String, Object> summary = (Map<String, Object>) dashboard.get('summary');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, summary.get('availableInventoryPositionCount'));
        System.assertEquals(1, summary.get('lowStockProductCount'));
        System.assertEquals(2, summary.get('lowStockInventoryPositionCount'));
    }

    @IsTest
    static void dashboardSummarizesDmsInvoicesAndPendingReturns() {
        Account distributor = createDistributor(
            'Invoice Dashboard Distributor',
            DISTRIBUTOR_A_TOKEN
        );
        Account outlet = new Account(
            Name = 'Invoice Dashboard Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributor.Id
        );
        insert outlet;
        Order secondaryOrder = new Order(
            AccountId = distributor.Id,
            Outlet__c = outlet.Id,
            Type = 'Secondary Order',
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert secondaryOrder;
        insert new List<DMS_Invoice__c>{
            new DMS_Invoice__c(
                Distributor__c = distributor.Id,
                Retailer__c = outlet.Id,
                Secondary_Order__c = secondaryOrder.Id,
                Invoice_Date__c = Date.today(),
                Status__c = 'Posted',
                Invoice_Total__c = 125,
                Balance_Due__c = 100
            ),
            new DMS_Invoice__c(
                Distributor__c = distributor.Id,
                Retailer__c = outlet.Id,
                Secondary_Order__c = secondaryOrder.Id,
                Invoice_Date__c = Date.today(),
                Status__c = 'Draft',
                Invoice_Total__c = 50,
                Balance_Due__c = 0
            )
        };
        insert new List<Return_Request__c>{
            new Return_Request__c(
                Distributor__c = distributor.Id,
                Outlet__c = outlet.Id,
                Return_Reason__c = 'Damaged',
                Status__c = 'Draft',
                Return_Date__c = System.now(),
                Request_Key__c = 'DASHBOARD-RETURN-DRAFT'
            ),
            new Return_Request__c(
                Distributor__c = distributor.Id,
                Outlet__c = outlet.Id,
                Return_Reason__c = 'Expired',
                Status__c = 'Submitted',
                Return_Date__c = System.now(),
                Request_Key__c = 'DASHBOARD-RETURN-SUBMITTED'
            )
        };

        setRequest(DISTRIBUTOR_A_TOKEN);
        DMSDistributorDashboardResource.getDashboard();

        Map<String, Object> dashboard = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Map<String, Object> summary = (Map<String, Object>) dashboard.get('summary');
        List<Object> recentInvoices = (List<Object>) dashboard.get('recentInvoices');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(2, summary.get('invoiceRecordCount'));
        System.assertEquals(100, summary.get('outstandingInvoiceAmount'));
        System.assertEquals(1, summary.get('outstandingInvoiceCount'));
        System.assertEquals(2, summary.get('pendingReturnCount'));
        System.assertEquals(2, recentInvoices.size());
        System.assertNotEquals(
            null,
            ((Map<String, Object>) recentInvoices[0]).get('invoiceNumber')
        );
    }

    @IsTest
    static void dashboardReturnsDistributorBeatsOutletsAndProducts() {
        Account distributorA = createDistributor('Beat Dashboard Distributor A', DISTRIBUTOR_A_TOKEN);
        Account distributorB = createDistributor('Beat Dashboard Distributor B', DISTRIBUTOR_B_TOKEN);

        Account linkedOutlet = new Account(
            Name = 'Dashboard Linked Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributorA.Id
        );
        Account unassignedOutlet = new Account(
            Name = 'Dashboard Unassigned Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributorA.Id
        );
        Account otherDistributorOutlet = new Account(
            Name = 'Dashboard Other Distributor Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Distributor__c = distributorB.Id
        );
        insert new List<Account>{ linkedOutlet, unassignedOutlet, otherDistributorOutlet };

        Beat__c beatWithOutlet = new Beat__c(
            Name = 'Dashboard Beat With Outlet',
            Distributor__c = distributorA.Id,
            Active__c = 'Yes'
        );
        Beat__c beatWithoutOutlet = new Beat__c(
            Name = 'Dashboard Beat Without Outlet',
            Distributor__c = distributorA.Id,
            Active__c = 'Yes'
        );
        Beat__c otherDistributorBeat = new Beat__c(
            Name = 'Dashboard Other Distributor Beat',
            Distributor__c = distributorB.Id,
            Active__c = 'Yes'
        );
        insert new List<Beat__c>{ beatWithOutlet, beatWithoutOutlet, otherDistributorBeat };
        update new Account(
            Id = linkedOutlet.Id,
            Beat__c = beatWithOutlet.Id
        );

        Product2 product = new Product2(
            Name = 'Dashboard Test Product',
            ProductCode = 'DASHBOARD-TEST',
            QuantityUnitOfMeasure = 'Piece',
            SFA_Product__c = true,
            IsActive = true
        );
        insert product;
        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);
        insert new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 25,
            IsActive = true,
            Unit_of_Measure__c = 'Piece',
            Unit_Conversion_Factor__c = 1
        );
        Pricebook2 primaryPricebook = new Pricebook2(
            Name = 'Dashboard Primary Pricebook',
            IsActive = true,
            Sales_Type__c = 'Primary'
        );
        insert primaryPricebook;
        insert new PricebookEntry(
            Pricebook2Id = primaryPricebook.Id,
            Product2Id = product.Id,
            UnitPrice = 25,
            IsActive = true,
            Unit_of_Measure__c = 'Case',
            Unit_Conversion_Factor__c = 60
        );
        Product2 nonSfaProduct = new Product2(
            Name = 'Dashboard Non-SFA Product',
            ProductCode = 'DASHBOARD-NON-SFA',
            QuantityUnitOfMeasure = 'Piece',
            SFA_Product__c = false,
            IsActive = true
        );
        insert nonSfaProduct;
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = nonSfaProduct.Id,
                UnitPrice = 10,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = primaryPricebook.Id,
                Product2Id = nonSfaProduct.Id,
                UnitPrice = 10,
                IsActive = true,
                Unit_of_Measure__c = 'Piece',
                Unit_Conversion_Factor__c = 1
            )
        };
        List<Scheme__c> schemes = new List<Scheme__c>{
            new Scheme__c(
                Scheme_Name__c = 'Dashboard Primary Scheme',
                Scheme_Type__c = 'Free Product',
                Sales_Type__c = 'Primary',
                Active__c = true,
                Status__c = 'Active',
                Start_Date__c = Date.today(),
                End_Date__c = Date.today().addDays(5)
            ),
            new Scheme__c(
                Scheme_Name__c = 'Dashboard Secondary Scheme',
                Scheme_Type__c = 'Free Product',
                Sales_Type__c = 'Secondary',
                Active__c = true,
                Status__c = 'Active',
                Start_Date__c = Date.today(),
                End_Date__c = Date.today().addDays(5)
            )
        };
        insert schemes;
        insert new List<Scheme_Product__c>{
            new Scheme_Product__c(
                Scheme__c = schemes[0].Id,
                Product__c = product.Id,
                Minimum_Quantity__c = 1,
                Minimum_Unit__c = 'Case',
                Free_Quantity__c = 1,
                Free_Unit__c = 'Case',
                Active__c = true
            ),
            new Scheme_Product__c(
                Scheme__c = schemes[1].Id,
                Product__c = product.Id,
                Minimum_Quantity__c = 10,
                Minimum_Unit__c = 'Piece',
                Free_Quantity__c = 1,
                Free_Unit__c = 'Piece',
                Active__c = true
            )
        };

        setRequest(DISTRIBUTOR_A_TOKEN);
        Test.startTest();
        DMSDistributorDashboardResource.getDashboard();
        Test.stopTest();

        Map<String, Object> dashboard = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        List<Object> beats = (List<Object>) dashboard.get('beats');
        List<Object> outlets = (List<Object>) dashboard.get('outlets');
        List<Object> products = (List<Object>) dashboard.get('products');
        List<Object> activeSchemes = (List<Object>) dashboard.get('activeSchemes');

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(2, beats.size(), 'Only the authenticated distributor beats should be returned.');
        System.assertEquals(2, outlets.size(), 'Only the authenticated distributor outlets should be returned.');
        System.assertEquals(
            1,
            products.size(),
            'Only SFA products from channel-specific price books should be returned.'
        );
        System.assertEquals(
            'Primary',
            ((Map<String, Object>) products[0]).get('salesType')
        );
        System.assertEquals(2, activeSchemes.size());
        Set<String> schemeSalesTypes = new Set<String>();
        for (Object schemeValue : activeSchemes) {
            schemeSalesTypes.add(
                (String) ((Map<String, Object>) schemeValue).get('salesType')
            );
        }
        System.assertEquals(new Set<String>{ 'Primary', 'Secondary' }, schemeSalesTypes);

        Set<String> returnedBeatNames = new Set<String>();
        for (Object beatValue : beats) {
            Map<String, Object> beat = (Map<String, Object>) beatValue;
            returnedBeatNames.add((String) beat.get('name'));
        }
        System.assertEquals(
            new Set<String>{ beatWithOutlet.Name, beatWithoutOutlet.Name },
            returnedBeatNames,
            'Beat records should be filtered directly by their distributor lookup.'
        );

        Set<String> returnedOutletIds = new Set<String>();
        for (Object outletValue : outlets) {
            Map<String, Object> outlet = (Map<String, Object>) outletValue;
            returnedOutletIds.add((String) outlet.get('id'));
            if ((String) outlet.get('id') == (String) linkedOutlet.Id) {
                System.assertEquals((String) beatWithOutlet.Id, outlet.get('beatId'));
                System.assertEquals(beatWithOutlet.Name, outlet.get('beatName'));
            }
        }
        System.assert(returnedOutletIds.contains((String) linkedOutlet.Id));
        System.assert(returnedOutletIds.contains((String) unassignedOutlet.Id));
        System.assert(!returnedOutletIds.contains((String) otherDistributorOutlet.Id));
    }

    @IsTest
    static void dashboardRejectsUnknownAndExpiredTokens() {
        createDistributor(
            'Expired Dashboard Distributor',
            DISTRIBUTOR_A_TOKEN,
            System.now().addMinutes(-1)
        );

        setRequest(DISTRIBUTOR_B_TOKEN);
        DMSDistributorDashboardResource.getDashboard();
        System.assertEquals(401, RestContext.response.statusCode);

        setRequest(DISTRIBUTOR_A_TOKEN);
        RestContext.response = new RestResponse();
        DMSDistributorDashboardResource.getDashboard();
        System.assertEquals(401, RestContext.response.statusCode);
    }

    @IsTest
    static void logoutRevokesTheServerSession() {
        Account distributor = createDistributor('Logout Dashboard Distributor', DISTRIBUTOR_A_TOKEN);

        setRequest(DISTRIBUTOR_A_TOKEN);
        DMSDistributorDashboardResource.logout();
        System.assertEquals(200, RestContext.response.statusCode);

        Account revoked = [
            SELECT DMS_Session_Token_Hash__c, DMS_Session_Expires_At__c
            FROM Account
            WHERE Id = :distributor.Id
        ];
        System.assertEquals(null, revoked.DMS_Session_Token_Hash__c);
        System.assertEquals(null, revoked.DMS_Session_Expires_At__c);

        setRequest(DISTRIBUTOR_A_TOKEN);
        DMSDistributorDashboardResource.getDashboard();
        System.assertEquals(401, RestContext.response.statusCode);
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
}
