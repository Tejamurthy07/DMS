@RestResource(urlMapping='/dms/v1/barcodes/*')
global without sharing class DMSBarcodeLookupResource {
    @HttpGet
    global static void getBarcode() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        Account distributor = DMSDistributorSessionAccessService.findDistributor(
            getSessionToken()
        );
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }

        String barcode = RestContext.request.params.get('barcode');
        if (String.isBlank(barcode) || barcode.trim().length() > 50) {
            writeResponse(response, 400, new Map<String, Object>{
                'success' => false,
                'message' => 'Enter a barcode up to 50 characters long.'
            });
            return;
        }
        barcode = barcode.trim();

        List<Product2> products = [
            SELECT Id, Name, ProductCode, Barcode__c, IsActive,
                   SFA_Product__c, QuantityUnitOfMeasure, Category__c, Family
            FROM Product2
            WHERE Barcode__c = :barcode
            LIMIT 2
        ];
        if (products.isEmpty()) {
            writeResponse(response, 404, new Map<String, Object>{
                'success' => false,
                'code' => 'not_found',
                'message' => 'No product matches this barcode.'
            });
            return;
        }
        if (products.size() > 1) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'code' => 'duplicate_barcode',
                'message' => 'This barcode is assigned to more than one product. Contact an administrator.'
            });
            return;
        }

        Product2 product = products[0];
        if (!product.IsActive || product.SFA_Product__c != true) {
            writeResponse(response, 409, new Map<String, Object>{
                'success' => false,
                'code' => 'inactive_product',
                'message' => 'This barcode belongs to an inactive or unavailable product.'
            });
            return;
        }

        List<Map<String, Object>> stock = new List<Map<String, Object>>();
        for (Inventory__c record : [
            SELECT Id, Warehouse__c, Warehouse__r.Name,
                   Warehouse__r.Warehouse_Code__c,
                   Available_Quantity__c, Reserved_Quantity__c,
                   Minimum_Stock_Level__c, Stock_Status__c
            FROM Inventory__c
            WHERE Product__c = :product.Id
              AND Warehouse__r.Distributor__c = :distributor.Id
              AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ORDER BY Warehouse__r.Name
            LIMIT 2000
        ]) {
            Decimal available = record.Available_Quantity__c == null
                ? 0
                : record.Available_Quantity__c;
            Decimal reserved = record.Reserved_Quantity__c == null
                ? 0
                : record.Reserved_Quantity__c;
            stock.add(new Map<String, Object>{
                'inventoryId' => record.Id,
                'warehouseId' => record.Warehouse__c,
                'warehouseName' => record.Warehouse__r == null
                    ? null
                    : record.Warehouse__r.Name,
                'warehouseCode' => record.Warehouse__r == null
                    ? null
                    : record.Warehouse__r.Warehouse_Code__c,
                'availableQuantity' => available,
                'reservedQuantity' => reserved,
                'onHandQuantity' => available + reserved,
                'minimumStockLevel' => record.Minimum_Stock_Level__c,
                'stockStatus' => record.Stock_Status__c
            });
        }

        List<Map<String, Object>> batches = new List<Map<String, Object>>();
        for (Product_Batch__c batch : [
            SELECT Id, Name, Warehouse__c, Warehouse__r.Name,
                   Manufacturing_Date__c, Expiry_Date__c, Batch_Quantity__c
            FROM Product_Batch__c
            WHERE Product__c = :product.Id
              AND Warehouse__r.Distributor__c = :distributor.Id
              AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ORDER BY Expiry_Date__c ASC, Name
            LIMIT 2000
        ]) {
            batches.add(new Map<String, Object>{
                'id' => batch.Id,
                'batchNumber' => batch.Name,
                'warehouseId' => batch.Warehouse__c,
                'warehouseName' => batch.Warehouse__r == null
                    ? null
                    : batch.Warehouse__r.Name,
                'manufacturingDate' => batch.Manufacturing_Date__c,
                'expiryDate' => batch.Expiry_Date__c,
                'quantity' => batch.Batch_Quantity__c
            });
        }

        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'product' => new Map<String, Object>{
                'id' => product.Id,
                'name' => product.Name,
                'productCode' => product.ProductCode,
                'barcode' => product.Barcode__c,
                'unitOfMeasure' => product.QuantityUnitOfMeasure,
                'category' => product.Category__c,
                'family' => product.Family,
                'isActive' => product.IsActive
            },
            'stock' => stock,
            'batches' => batches
        });
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
}
