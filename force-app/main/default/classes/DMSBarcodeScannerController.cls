public with sharing class DMSBarcodeScannerController {
    private static final String COMPANY_PERMISSION = 'DMS_Company_Inventory_Access';
    private static final Set<String> SCANNABLE_DISPATCH_STATUSES =
        new Set<String>{ 'Draft', 'Submitted', 'Approved' };

    @AuraEnabled
    public static Map<String, Object> lookupBarcode(String barcode) {
        if (String.isBlank(barcode) || barcode.trim().length() > 50) {
            throw new AuraHandledException('Enter a barcode up to 50 characters long.');
        }

        String normalizedBarcode = barcode.trim();
        List<Product2> products;
        try {
            products = [
                SELECT Id, Name, ProductCode, Barcode__c, IsActive,
                       QuantityUnitOfMeasure
                FROM Product2
                WHERE Barcode__c = :normalizedBarcode
                WITH USER_MODE
                LIMIT 2
            ];
        } catch (QueryException error) {
            throw new AuraHandledException(
                'You do not have permission to read the product barcode fields.'
            );
        }

        if (products.isEmpty()) {
            throw new AuraHandledException('No product matches this barcode.');
        }
        if (products.size() > 1) {
            throw new AuraHandledException(
                'This barcode is assigned to more than one product. Contact an administrator.'
            );
        }

        Product2 product = products[0];
        if (!product.IsActive) {
            throw new AuraHandledException(
                'This barcode belongs to an inactive product.'
            );
        }

        List<Map<String, Object>> stock = new List<Map<String, Object>>();
        try {
            for (Inventory__c record : [
                SELECT Id, Warehouse__c, Warehouse__r.Name,
                       Available_Quantity__c, Reserved_Quantity__c,
                       Stock_Status__c
                FROM Inventory__c
                WHERE Product__c = :product.Id
                WITH USER_MODE
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
                    'availableQuantity' => available,
                    'reservedQuantity' => reserved,
                    'onHandQuantity' => available + reserved,
                    'stockStatus' => record.Stock_Status__c
                });
            }
        } catch (QueryException error) {
            throw new AuraHandledException(
                'You do not have permission to read inventory for this product.'
            );
        }

        return new Map<String, Object>{
            'product' => new Map<String, Object>{
                'id' => product.Id,
                'name' => product.Name,
                'productCode' => product.ProductCode,
                'barcode' => product.Barcode__c,
                'unitOfMeasure' => product.QuantityUnitOfMeasure
            },
            'stock' => stock
        };
    }

    @AuraEnabled
    public static Map<String, Object> getDispatchLines(Id dispatchId) {
        requireCompanyOperator();
        if (dispatchId == null) {
            throw new AuraHandledException('Open a Primary Dispatch record to scan its products.');
        }

        DMS_Dispatch__c dispatch = getScannablePrimaryDispatch(dispatchId);
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        for (DMS_Dispatch_Line__c line : [
            SELECT Id, Product__c, Product__r.Name, Product__r.ProductCode,
                   Product__r.Barcode__c, Product__r.QuantityUnitOfMeasure,
                   Quantity__c, Unit_of_Measure__c, Scanned_Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id
            WITH USER_MODE
            ORDER BY CreatedDate, Id
        ]) {
            Decimal quantity = line.Quantity__c == null ? 0 : line.Quantity__c;
            Decimal scanned = line.Scanned_Quantity__c == null
                ? 0
                : line.Scanned_Quantity__c;
            lines.add(new Map<String, Object>{
                'id' => line.Id,
                'productId' => line.Product__c,
                'productName' => line.Product__r == null ? null : line.Product__r.Name,
                'productCode' => line.Product__r == null ? null : line.Product__r.ProductCode,
                'barcode' => line.Product__r == null ? null : line.Product__r.Barcode__c,
                'productUnit' => line.Product__r == null
                    ? null
                    : line.Product__r.QuantityUnitOfMeasure,
                'unitOfMeasure' => line.Unit_of_Measure__c,
                'quantity' => quantity,
                'scannedQuantity' => scanned,
                'remainingQuantity' => Math.max(0, quantity - scanned)
            });
        }
        if (lines.isEmpty()) {
            throw new AuraHandledException('This Primary Dispatch has no product lines to scan.');
        }
        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'dispatchNumber' => dispatch.Name,
            'status' => dispatch.Status__c,
            'lines' => lines
        };
    }

    @AuraEnabled
    public static Map<String, Object> scanDispatchBarcode(Id dispatchId, String barcode) {
        requireCompanyOperator();
        if (dispatchId == null || String.isBlank(barcode) || barcode.trim().length() > 50) {
            throw new AuraHandledException('Enter a valid dispatch and barcode.');
        }
        if (!Schema.sObjectType.DMS_Dispatch_Line__c.isUpdateable()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.fields.Scanned_Quantity__c.isUpdateable()) {
            throw new AuraHandledException(
                'You do not have permission to record barcode verification progress.'
            );
        }

        DMS_Dispatch__c dispatch = getScannablePrimaryDispatch(dispatchId);
        List<Product2> products = [
            SELECT Id, Name, ProductCode, Barcode__c, IsActive, QuantityUnitOfMeasure
            FROM Product2
            WHERE Barcode__c = :barcode.trim()
            WITH USER_MODE
            LIMIT 2
        ];
        if (products.isEmpty()) {
            throw new AuraHandledException('No product matches this barcode.');
        }
        if (products.size() > 1) {
            throw new AuraHandledException(
                'This barcode matches more than one product. Contact an administrator.'
            );
        }
        Product2 product = products[0];
        if (!product.IsActive) {
            throw new AuraHandledException('This barcode belongs to an inactive product.');
        }

        requireDispatchLineFieldAccess();
        List<DMS_Dispatch_Line__c> lines = [
            SELECT Id, Product__c, Quantity__c, Unit_of_Measure__c,
                   Order_Line_Item__r.Unit_Conversion_Factor__c,
                   Scanned_Quantity__c
            FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatch.Id AND Product__c = :product.Id
            FOR UPDATE
        ];
        if (lines.isEmpty()) {
            throw new AuraHandledException(
                product.Name + ' is not linked to this Primary Dispatch.'
            );
        }
        if (lines.size() > 1) {
            throw new AuraHandledException(
                'This product has multiple lines on the dispatch. Verify its line manually.'
            );
        }

        DMS_Dispatch_Line__c line = lines[0];
        String productUnit = product.QuantityUnitOfMeasure == null
            ? ''
            : product.QuantityUnitOfMeasure.trim().toLowerCase();
        String dispatchUnit = line.Unit_of_Measure__c == null
            ? ''
            : line.Unit_of_Measure__c.trim().toLowerCase();
        Decimal conversionFactor = line.Order_Line_Item__r == null
            || line.Order_Line_Item__r.Unit_Conversion_Factor__c == null
            ? 1
            : line.Order_Line_Item__r.Unit_Conversion_Factor__c;
        if (String.isBlank(productUnit) || productUnit != dispatchUnit
            || conversionFactor != 1) {
            throw new AuraHandledException(
                'The barcode packaging unit does not match the dispatch line unit. Verify the quantity manually.'
            );
        }

        Decimal quantity = line.Quantity__c == null ? 0 : line.Quantity__c;
        Decimal scanned = line.Scanned_Quantity__c == null
            ? 0
            : line.Scanned_Quantity__c;
        if (quantity <= 0 || quantity != quantity.setScale(0, RoundingMode.DOWN)
            || scanned != scanned.setScale(0, RoundingMode.DOWN)
            || scanned + 1 > quantity) {
            throw new AuraHandledException(
                'This line cannot accept another whole-unit scan for ' + product.Name +
                '. Verify fractional or completed quantities manually.'
            );
        }
        line.Scanned_Quantity__c = scanned + 1;
        try {
            update as user line;
        } catch (DmlException error) {
            throw new AuraHandledException(
                'Barcode verification progress could not be saved. Check your dispatch-line access.'
            );
        }

        return new Map<String, Object>{
            'dispatchId' => dispatch.Id,
            'lineId' => line.Id,
            'productId' => product.Id,
            'productName' => product.Name,
            'unitOfMeasure' => line.Unit_of_Measure__c,
            'scannedQuantity' => line.Scanned_Quantity__c,
            'remainingQuantity' => quantity - line.Scanned_Quantity__c,
            'inventoryChanged' => false
        };
    }

    private static DMS_Dispatch__c getScannablePrimaryDispatch(Id dispatchId) {
        if (!Schema.sObjectType.DMS_Dispatch__c.isAccessible()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.isAccessible()) {
            throw new AuraHandledException('You do not have permission to read dispatch lines.');
        }
        List<DMS_Dispatch__c> dispatches = [
            SELECT Id, Name, Status__c, Order__c, Order__r.Type,
                   Order__r.Status, Order__r.AccountId,
                   Invoice__c, Invoice__r.Status__c, Invoice__r.Distributor__c,
                   Invoice__r.Warehouse__c, Invoice__r.Secondary_Order__c,
                   Distributor__c, Warehouse__c, Warehouse__r.Warehouse_Type__c,
                   Warehouse__r.Distributor__c, Warehouse__r.Warehouse_Status__c
            FROM DMS_Dispatch__c
            WHERE Id = :dispatchId
            WITH USER_MODE
            LIMIT 1
        ];
        if (dispatches.isEmpty()) {
            throw new AuraHandledException('The Primary Dispatch is unavailable to your user.');
        }

        DMS_Dispatch__c dispatch = dispatches[0];
        if (dispatch.Order__r == null || dispatch.Order__r.Type != 'Primary Order'
            || dispatch.Order__r.Status != 'Activated'
            || dispatch.Order__r.AccountId != dispatch.Distributor__c
            || dispatch.Warehouse__r == null
            || dispatch.Warehouse__r.Warehouse_Type__c != 'Company Warehouse'
            || dispatch.Warehouse__r.Distributor__c != null
            || dispatch.Warehouse__r.Warehouse_Status__c != 'Active'
            || dispatch.Invoice__r == null
            || dispatch.Invoice__r.Status__c != 'Posted'
            || dispatch.Invoice__r.Distributor__c != dispatch.Distributor__c
            || dispatch.Invoice__r.Warehouse__c != dispatch.Warehouse__c
            || dispatch.Invoice__r.Secondary_Order__c != dispatch.Order__c) {
            throw new AuraHandledException(
                'Barcode verification is available only for a valid company Primary Dispatch.'
            );
        }
        if (!SCANNABLE_DISPATCH_STATUSES.contains(dispatch.Status__c)) {
            throw new AuraHandledException(
                'This Primary Dispatch is not in a scannable status.'
            );
        }
        return dispatch;
    }

    private static void requireCompanyOperator() {
        if (UserInfo.getUserType() == 'Guest'
            || !FeatureManagement.checkPermission(COMPANY_PERMISSION)) {
            throw new AuraHandledException(
                'You are not authorized to scan company Primary Dispatches.'
            );
        }
    }

    private static void requireDispatchLineFieldAccess() {
        if (!Schema.sObjectType.DMS_Dispatch_Line__c.isAccessible()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.fields.Product__c.isAccessible()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.fields.Quantity__c.isAccessible()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.fields.Unit_of_Measure__c.isAccessible()
            || !Schema.sObjectType.DMS_Dispatch_Line__c.fields.Scanned_Quantity__c.isAccessible()
            || !Schema.sObjectType.OrderItem.fields.Unit_Conversion_Factor__c.isAccessible()) {
            throw new AuraHandledException('You do not have permission to verify these dispatch lines.');
        }
    }
}
