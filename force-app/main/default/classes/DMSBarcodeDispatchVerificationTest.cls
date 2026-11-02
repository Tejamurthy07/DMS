@IsTest
private class DMSBarcodeDispatchVerificationTest {
    @IsTest
    static void dispatchScanIsScopedAndDoesNotChangeInventory() {
        User companyUser = createCompanyUser();
        System.runAs(companyUser) {
            Account distributor = new Account(Name = 'Barcode Dispatch Distributor');
            insert distributor;
            Warehouse__c warehouse = new Warehouse__c(
                Name = 'Barcode Dispatch Company Warehouse',
                Warehouse_Type__c = 'Company Warehouse',
                Warehouse_Status__c = 'Active'
            );
            insert warehouse;

            Product2 product = new Product2(
                Name = 'Barcode Dispatch Product',
                ProductCode = 'BAR-DISPATCH-1',
                Barcode__c = '8901234567012',
                IsActive = true,
                QuantityUnitOfMeasure = 'Piece'
            );
            Product2 unrelatedProduct = new Product2(
                Name = 'Unrelated Barcode Dispatch Product',
                ProductCode = 'BAR-DISPATCH-2',
                Barcode__c = '8901234567029',
                IsActive = true,
                QuantityUnitOfMeasure = 'Piece'
            );
            insert new List<Product2>{ product, unrelatedProduct };

            Id standardPricebookId = Test.getStandardPricebookId();
            update new Pricebook2(Id = standardPricebookId, IsActive = true);
            PricebookEntry productEntry = new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = product.Id,
                UnitPrice = 15,
                IsActive = true
            );
            insert productEntry;
            Order primaryOrder = new Order(
                AccountId = distributor.Id,
                EffectiveDate = Date.today(),
                Status = 'Draft',
                Type = 'Primary Order',
                Pricebook2Id = standardPricebookId
            );
            insert primaryOrder;
            OrderItem orderLine = new OrderItem(
                OrderId = primaryOrder.Id,
                PricebookEntryId = productEntry.Id,
                Quantity = 2,
                UnitPrice = 15,
                Paid_Quantity__c = 2,
                Free_Quantity__c = 0,
                Unit_of_Measure__c = 'Piece',
                Unit_Conversion_Factor__c = 1
            );
            insert orderLine;
            update new Order(Id = primaryOrder.Id, Status = 'Activated');
            DMS_Invoice__c invoice = new DMS_Invoice__c(
                Invoice_Date__c = Date.today(),
                Distributor__c = distributor.Id,
                Retailer__c = distributor.Id,
                Secondary_Order__c = primaryOrder.Id,
                Warehouse__c = warehouse.Id,
                Status__c = 'Posted',
                Stock_Deduction_Status__c = 'Pending Dispatch',
                Invoice_Total__c = 30,
                Balance_Due__c = 30
            );
            insert invoice;
            DMS_Dispatch__c dispatch = new DMS_Dispatch__c(
                Order__c = primaryOrder.Id,
                Invoice__c = invoice.Id,
                Distributor__c = distributor.Id,
                Warehouse__c = warehouse.Id,
                Status__c = 'Draft'
            );
            insert dispatch;
            DMS_Dispatch_Line__c dispatchLine = new DMS_Dispatch_Line__c(
                Dispatch__c = dispatch.Id,
                Product__c = product.Id,
                Order_Line_Item__c = orderLine.Id,
                Quantity__c = 2,
                Unit_of_Measure__c = 'Piece',
                Scanned_Quantity__c = 0
            );
            insert dispatchLine;
            Inventory__c inventory = new Inventory__c(
                Warehouse__c = warehouse.Id,
                Product__c = product.Id,
                Available_Quantity__c = 23,
                Reserved_Quantity__c = 1
            );
            insert inventory;

            Map<String, Object> initialState =
                DMSBarcodeScannerController.getDispatchLines(dispatch.Id);
            List<Object> lines = (List<Object>) initialState.get('lines');
            System.assertEquals(1, lines.size());
            System.assertEquals('8901234567012', ((Map<String, Object>) lines[0]).get('barcode'));

            Map<String, Object> firstScan =
                DMSBarcodeScannerController.scanDispatchBarcode(
                    dispatch.Id,
                    '8901234567012'
                );
            Map<String, Object> secondScan =
                DMSBarcodeScannerController.scanDispatchBarcode(
                    dispatch.Id,
                    '8901234567012'
                );
            System.assertEquals(1, firstScan.get('scannedQuantity'));
            System.assertEquals(0, secondScan.get('remainingQuantity'));
            System.assertEquals(false, secondScan.get('inventoryChanged'));

            assertScanThrows(dispatch.Id, '8901234567012');
            assertScanThrows(dispatch.Id, 'UNKNOWN-BARCODE');
            assertScanThrows(dispatch.Id, '8901234567029');

            DMS_Dispatch_Line__c persistedLine = [
                SELECT Scanned_Quantity__c
                FROM DMS_Dispatch_Line__c
                WHERE Id = :dispatchLine.Id
            ];
            Inventory__c unchangedInventory = [
                SELECT Available_Quantity__c, Reserved_Quantity__c
                FROM Inventory__c
                WHERE Id = :inventory.Id
            ];
            System.assertEquals(2, persistedLine.Scanned_Quantity__c);
            System.assertEquals(23, unchangedInventory.Available_Quantity__c);
            System.assertEquals(1, unchangedInventory.Reserved_Quantity__c);
        }
    }

    @IsTest
    static void dispatchScanRequiresCompanyPermission() {
        Boolean denied = false;
        try {
            DMSBarcodeScannerController.getDispatchLines(null);
        } catch (AuraHandledException error) {
            denied = true;
        }
        System.assert(denied, 'A user without the company permission must be denied.');
    }

    private static void assertScanThrows(Id dispatchId, String barcode) {
        Boolean didThrow = false;
        try {
            DMSBarcodeScannerController.scanDispatchBarcode(dispatchId, barcode);
        } catch (AuraHandledException error) {
            didThrow = true;
        }
        System.assert(didThrow, 'An ineligible barcode scan must be rejected.');
    }

    private static User createCompanyUser() {
        PermissionSet companyAccess = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'DMS_Company_Inventory_Access'
            LIMIT 1
        ];
        String suffix = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(System.now().getTime())))
        ).substring(0, 10);
        User companyUser = new User(
            Alias = 'dmsbar',
            Email = 'barcode-dispatch-' + suffix + '@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Barcode Dispatch Operator',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'barcode.dispatch.' + suffix + '@example.invalid'
        );
        insert companyUser;
        insert new PermissionSetAssignment(
            AssigneeId = companyUser.Id,
            PermissionSetId = companyAccess.Id
        );
        return companyUser;
    }
}
