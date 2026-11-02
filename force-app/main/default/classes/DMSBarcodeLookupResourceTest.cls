@IsTest
private class DMSBarcodeLookupResourceTest {
    private static final String TOKEN =
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

    @IsTest
    static void lookupReturnsProductAndOnlyCurrentDistributorsStockAndBatches() {
        Account distributor = createDistributor('Barcode Distributor', TOKEN);
        Account otherDistributor = createDistributor(
            'Other Barcode Distributor',
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        );
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Barcode Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        Warehouse__c otherWarehouse = new Warehouse__c(
            Name = 'Other Barcode Warehouse',
            Distributor__c = otherDistributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert new List<Warehouse__c>{ warehouse, otherWarehouse };

        Product2 product = new Product2(
            Name = 'Barcode Test Product',
            ProductCode = 'BAR-TEST',
            Barcode__c = '8901234567890',
            IsActive = true,
            SFA_Product__c = true,
            QuantityUnitOfMeasure = 'Piece'
        );
        insert product;
        Inventory__c inventory = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = product.Id,
            Available_Quantity__c = 8,
            Reserved_Quantity__c = 2,
            Minimum_Stock_Level__c = 5
        );
        insert new List<Inventory__c>{
            inventory,
            new Inventory__c(
                Warehouse__c = otherWarehouse.Id,
                Product__c = product.Id,
                Available_Quantity__c = 100,
                Reserved_Quantity__c = 0,
                Minimum_Stock_Level__c = 5
            )
        };
        insert new List<Product_Batch__c>{
            new Product_Batch__c(
                Name = 'BAR-TEST-BATCH',
                Product__c = product.Id,
                Warehouse__c = warehouse.Id,
                Expiry_Date__c = Date.today().addDays(30),
                Batch_Quantity__c = 8
            ),
            new Product_Batch__c(
                Name = 'OTHER-BAR-TEST-BATCH',
                Product__c = product.Id,
                Warehouse__c = otherWarehouse.Id,
                Expiry_Date__c = Date.today().addDays(30),
                Batch_Quantity__c = 100
            )
        };

        setRequest(TOKEN, ' 8901234567890 ');
        Test.startTest();
        DMSBarcodeLookupResource.getBarcode();
        Test.stopTest();

        Map<String, Object> payload = parseResponse();
        Map<String, Object> resultProduct = (Map<String, Object>) payload.get('product');
        List<Object> stock = (List<Object>) payload.get('stock');
        List<Object> batches = (List<Object>) payload.get('batches');
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(product.Id, resultProduct.get('id'));
        System.assertEquals('8901234567890', resultProduct.get('barcode'));
        System.assertEquals('Piece', resultProduct.get('unitOfMeasure'));
        System.assertEquals(1, stock.size());
        System.assertEquals(8, ((Map<String, Object>) stock[0]).get('availableQuantity'));
        System.assertEquals(2, ((Map<String, Object>) stock[0]).get('reservedQuantity'));
        System.assertEquals(1, batches.size());
        System.assertEquals(
            'BAR-TEST-BATCH',
            ((Map<String, Object>) batches[0]).get('batchNumber')
        );

        Inventory__c unchangedInventory = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :inventory.Id
        ];
        System.assertEquals(8, unchangedInventory.Available_Quantity__c);
        System.assertEquals(2, unchangedInventory.Reserved_Quantity__c);
    }

    @IsTest
    static void lookupReportsInvalidUnknownAndInactiveBarcodes() {
        createDistributor('Barcode Status Distributor', TOKEN);
        insert new Product2(
            Name = 'Inactive Barcode Product',
            Barcode__c = 'INACTIVE-BARCODE',
            IsActive = false,
            SFA_Product__c = true
        );

        setRequest(TOKEN, '');
        DMSBarcodeLookupResource.getBarcode();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest(TOKEN, 'UNKNOWN-BARCODE');
        DMSBarcodeLookupResource.getBarcode();
        System.assertEquals(404, RestContext.response.statusCode);
        System.assertEquals('not_found', parseResponse().get('code'));

        setRequest(TOKEN, 'INACTIVE-BARCODE');
        DMSBarcodeLookupResource.getBarcode();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals('inactive_product', parseResponse().get('code'));

        setRequest(null, '8901234567890');
        DMSBarcodeLookupResource.getBarcode();
        System.assertEquals(401, RestContext.response.statusCode);
    }

    private static Account createDistributor(String name, String token) {
        Account distributor = new Account(
            Name = name,
            Email__c = name.replace(' ', '.') + '@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            DMS_Session_Token_Hash__c = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(token))
            ),
            DMS_Session_Expires_At__c = System.now().addHours(1)
        );
        insert distributor;
        return distributor;
    }

    private static void setRequest(String token, String barcode) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = 'GET';
        if (token != null) {
            RestContext.request.headers.put('x-dms-session', token);
        }
        if (barcode != null) {
            RestContext.request.params.put('barcode', barcode);
        }
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> parseResponse() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
    }
}
