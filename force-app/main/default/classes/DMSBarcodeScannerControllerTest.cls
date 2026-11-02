@IsTest
private class DMSBarcodeScannerControllerTest {
    @IsTest
    static void lookupReturnsProductAndVisibleStockWithoutChangingInventory() {
        Product2 product = new Product2(
            Name = 'LWC Barcode Test Product',
            ProductCode = 'LWC-BAR-TEST',
            Barcode__c = '8900000000001',
            IsActive = true,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert product;
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'LWC Barcode Test Warehouse',
            Warehouse_Type__c = 'Distributor Warehouse'
        );
        insert warehouse;
        Inventory__c inventory = new Inventory__c(
            Product__c = product.Id,
            Warehouse__c = warehouse.Id,
            Available_Quantity__c = 42
        );
        insert inventory;

        Map<String, Object> result;
        Test.startTest();
        result = DMSBarcodeScannerController.lookupBarcode(' 8900000000001 ');
        Test.stopTest();

        Map<String, Object> productResult = (Map<String, Object>) result.get('product');
        System.assertEquals(product.Id, productResult.get('id'));
        System.assertEquals('8900000000001', productResult.get('barcode'));
        System.assertEquals('LWC-BAR-TEST', productResult.get('productCode'));
        List<Object> stockResults = (List<Object>) result.get('stock');
        System.assertEquals(1, stockResults.size());
        Map<String, Object> stockResult = (Map<String, Object>) stockResults[0];
        System.assertEquals(inventory.Id, stockResult.get('inventoryId'));
        System.assertEquals(warehouse.Id, stockResult.get('warehouseId'));
        System.assertEquals('LWC Barcode Test Warehouse', stockResult.get('warehouseName'));
        System.assertEquals(Decimal.valueOf('42'), stockResult.get('availableQuantity'));
        System.assertEquals(Decimal.valueOf('0'), stockResult.get('reservedQuantity'));
        System.assertEquals(Decimal.valueOf('42'), stockResult.get('onHandQuantity'));
        Inventory__c persistedInventory = [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :inventory.Id
        ];
        System.assertEquals(Decimal.valueOf('42'), persistedInventory.Available_Quantity__c);
    }

    @IsTest
    static void lookupRejectsUnknownInactiveAndInvalidBarcodes() {
        insert new Product2(
            Name = 'Inactive LWC Barcode Test Product',
            Barcode__c = 'INACTIVE-LWC-BARCODE',
            IsActive = false
        );

        assertLookupThrows('', 'Blank barcode should not be accepted.');
        assertLookupThrows('UNKNOWN-LWC-BARCODE', 'Unknown barcode should not be accepted.');
        assertLookupThrows('INACTIVE-LWC-BARCODE', 'Inactive product should not be accepted.');
        assertLookupThrows(
            '123456789012345678901234567890123456789012345678901',
            'Barcodes longer than 50 characters should not be accepted.'
        );
    }

    private static void assertLookupThrows(String barcode, String assertionMessage) {
        Boolean didThrow = false;
        try {
            DMSBarcodeScannerController.lookupBarcode(barcode);
        } catch (AuraHandledException error) {
            didThrow = true;
        }
        System.assert(didThrow, assertionMessage);
    }
}
