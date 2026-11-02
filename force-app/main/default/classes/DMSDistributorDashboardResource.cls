@RestResource(urlMapping='/dms/v1/dashboard')
global without sharing class DMSDistributorDashboardResource {
    private static final Integer RECENT_ORDER_LIMIT = 6;
    private static final Integer PRODUCT_LIMIT = 8;

    @HttpGet
    global static void getDashboard() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        Account distributor = findDistributor(getBearerToken());
        if (distributor == null) {
            writeResponse(response, 401, new Map<String, Object>{
                'success' => false,
                'message' => 'Your DMS session is invalid or has expired. Sign in again.'
            });
            return;
        }

        try {
            List<Map<String, Object>> orderStatuses = new List<Map<String, Object>>();
            Integer totalOrders = 0;
            for (AggregateResult row : [
                SELECT Status orderStatus, COUNT(Id) orderCount
                FROM Order
                WHERE AccountId = :distributor.Id
                GROUP BY Status
            ]) {
                Integer countForStatus = (Integer) row.get('orderCount');
                totalOrders += countForStatus;
                orderStatuses.add(new Map<String, Object>{
                    'status' => row.get('orderStatus'),
                    'count' => countForStatus
                });
            }

            Integer primaryOrders = 0;
            Integer secondaryOrders = 0;
            Integer pendingPrimaryOrders = 0;
            Integer pendingSecondaryOrders = 0;
            Decimal primarySalesValue = 0;
            Decimal secondarySalesValue = 0;
            for (AggregateResult row : [
                SELECT Type salesType, Status orderStatus, COUNT(Id) orderCount,
                       SUM(TotalAmount) salesValue
                FROM Order
                WHERE AccountId = :distributor.Id
                  AND Type IN ('Primary Order', 'Secondary Order')
                GROUP BY Type, Status
            ]) {
                Integer countForType = (Integer) row.get('orderCount');
                Decimal valueForType = (Decimal) row.get('salesValue');
                if (valueForType == null) {
                    valueForType = 0;
                }
                if ((String) row.get('salesType') == 'Primary Order') {
                    primaryOrders += countForType;
                    primarySalesValue += valueForType;
                    if ((String) row.get('orderStatus') == 'Draft') {
                        pendingPrimaryOrders += countForType;
                    }
                } else if ((String) row.get('salesType') == 'Secondary Order') {
                    secondaryOrders += countForType;
                    secondarySalesValue += valueForType;
                    if ((String) row.get('orderStatus') == 'Draft') {
                        pendingSecondaryOrders += countForType;
                    }
                }
            }

            List<Map<String, Object>> recentOrders = new List<Map<String, Object>>();
            for (Order orderRecord : [
                SELECT Id, OrderNumber, Type, Status, EffectiveDate, TotalAmount, CreatedDate,
                       Outlet__c, Outlet__r.Name
                FROM Order
                WHERE AccountId = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT :RECENT_ORDER_LIMIT
            ]) {
                recentOrders.add(new Map<String, Object>{
                    'id' => orderRecord.Id,
                    'orderNumber' => orderRecord.OrderNumber,
                    'status' => orderRecord.Status,
                    'salesType' => orderRecord.Type == 'Primary Order'
                        ? 'Primary'
                        : (orderRecord.Type == 'Secondary Order' ? 'Secondary' : null),
                    'customerName' => orderRecord.Type == 'Secondary Order'
                        ? (orderRecord.Outlet__r == null ? null : orderRecord.Outlet__r.Name)
                        : distributor.Name,
                    'retailerId' => orderRecord.Outlet__c,
                    'retailerName' => orderRecord.Outlet__r == null
                        ? null
                        : orderRecord.Outlet__r.Name,
                    'orderDate' => orderRecord.EffectiveDate,
                    'totalAmount' => orderRecord.TotalAmount
                });
            }

            List<Map<String, Object>> beats = new List<Map<String, Object>>();
            for (Beat__c beatRecord : [
                SELECT Id, Name, Territory__c, Active__c, CreatedDate,
                       LastModifiedDate, Owner.Name
                FROM Beat__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY Name
            ]) {
                beats.add(new Map<String, Object>{
                    'id' => beatRecord.Id,
                    'name' => beatRecord.Name,
                    'territory' => beatRecord.Territory__c,
                    'active' => beatRecord.Active__c,
                    'recordOwner' => beatRecord.Owner == null ? null : beatRecord.Owner.Name,
                    'createdDate' => beatRecord.CreatedDate,
                    'lastModifiedDate' => beatRecord.LastModifiedDate
                });
            }

            List<Map<String, Object>> outlets = new List<Map<String, Object>>();
            for (Account outletRecord : [
                SELECT Id, Name, Account_Category__c, Active__c, Phone,
                       BillingStreet, BillingCity, BillingState, BillingPostalCode,
                       BillingCountry, Outlet_Owner_Name__c, Outlet_Segment__c,
                       Email__c, ShippingStreet, ShippingCity, ShippingState,
                       ShippingPostalCode, ShippingCountry, CreatedDate,
                       LastModifiedDate, Beat__c, Beat__r.Name
                FROM Account
                WHERE Distributor__c = :distributor.Id
                  AND Account_Category__c = 'Outlet'
                ORDER BY Name
            ]) {
                outlets.add(new Map<String, Object>{
                    'id' => outletRecord.Id,
                    'name' => outletRecord.Name,
                    'accountCategory' => outletRecord.Account_Category__c,
                    'active' => outletRecord.Active__c,
                    'phone' => outletRecord.Phone,
                    'email' => outletRecord.Email__c,
                    'ownerName' => outletRecord.Outlet_Owner_Name__c,
                    'segment' => outletRecord.Outlet_Segment__c,
                    'beatId' => outletRecord.Beat__c,
                    'beatName' => outletRecord.Beat__r == null
                        ? null
                        : outletRecord.Beat__r.Name,
                    'billingStreet' => outletRecord.BillingStreet,
                    'billingCity' => outletRecord.BillingCity,
                    'billingState' => outletRecord.BillingState,
                    'billingPostalCode' => outletRecord.BillingPostalCode,
                    'billingCountry' => outletRecord.BillingCountry,
                    'shippingStreet' => outletRecord.ShippingStreet,
                    'shippingCity' => outletRecord.ShippingCity,
                    'shippingState' => outletRecord.ShippingState,
                    'shippingPostalCode' => outletRecord.ShippingPostalCode,
                    'shippingCountry' => outletRecord.ShippingCountry,
                    'createdDate' => outletRecord.CreatedDate,
                    'lastModifiedDate' => outletRecord.LastModifiedDate
                });
            }

            AggregateResult productCountResult = [
                SELECT COUNT_DISTINCT(Product2Id) activeProductCount
                FROM PricebookEntry
                WHERE IsActive = true
                  AND Product2.IsActive = true
                  AND Product2.SFA_Product__c = true
                  AND Pricebook2.IsActive = true
                  AND Pricebook2.Sales_Type__c IN ('Primary', 'Secondary')
            ];
            Integer activeProductCount = (Integer) productCountResult.get('activeProductCount');

            AggregateResult invoiceSummary = [
                SELECT COUNT(Id) invoiceCount, SUM(Balance_Due__c) outstandingBalance
                FROM DMS_Invoice__c
                WHERE Distributor__c = :distributor.Id
                  AND Balance_Due__c > 0
            ];
            Decimal outstandingInvoiceAmount = (Decimal) invoiceSummary.get('outstandingBalance');

            AggregateResult invoiceRecordSummary = [
                SELECT COUNT(Id) invoiceRecordCount
                FROM DMS_Invoice__c
                WHERE Distributor__c = :distributor.Id
            ];
            Integer pendingReturnCount = [
                SELECT COUNT()
                FROM Return_Request__c
                WHERE Distributor__c = :distributor.Id
                  AND Status__c IN ('Draft', 'Submitted', 'Approved')
            ];

            Integer availableInventoryPositionCount = 0;
            Integer lowStockProductCount = 0;
            Set<Id> lowStockProductIds = new Set<Id>();
            Integer lowStockInventoryPositionCount = 0;
            for (Inventory__c inventoryRecord : [
                SELECT Product__c, Available_Quantity__c, Minimum_Stock_Level__c
                FROM Inventory__c
                WHERE Warehouse__r.Distributor__c = :distributor.Id
                  AND Warehouse__r.Warehouse_Type__c = 'Distributor Warehouse'
            ]) {
                Decimal availableQuantity = inventoryRecord.Available_Quantity__c == null
                    ? 0
                    : inventoryRecord.Available_Quantity__c;
                Decimal minimumStockLevel = inventoryRecord.Minimum_Stock_Level__c == null
                    ? 0
                    : inventoryRecord.Minimum_Stock_Level__c;
                if (availableQuantity > 0) {
                    if (availableQuantity > minimumStockLevel) {
                        availableInventoryPositionCount++;
                    } else {
                        lowStockProductIds.add(inventoryRecord.Product__c);
                        lowStockInventoryPositionCount++;
                    }
                }
            }
            lowStockProductCount = lowStockProductIds.size();

            List<Map<String, Object>> recentInvoices = new List<Map<String, Object>>();
            for (DMS_Invoice__c invoice : [
                SELECT Id, Name, Status__c, Invoice_Date__c, Invoice_Total__c,
                       Balance_Due__c, CreatedDate
                FROM DMS_Invoice__c
                WHERE Distributor__c = :distributor.Id
                ORDER BY CreatedDate DESC
                LIMIT 5
            ]) {
                recentInvoices.add(new Map<String, Object>{
                    'id' => invoice.Id,
                    'invoiceNumber' => invoice.Name,
                    'status' => invoice.Status__c,
                    'dueDate' => invoice.Invoice_Date__c,
                    'totalAmount' => invoice.Invoice_Total__c,
                    'balance' => invoice.Balance_Due__c
                });
            }

            List<Map<String, Object>> products = new List<Map<String, Object>>();
            for (PricebookEntry entry : [
                SELECT Id, UnitPrice, Pricebook2.Name, Product2Id,
                       Product2.Name, Product2.ProductCode, Product2.Description,
                       Product2.DisplayUrl, Product2.SFA_Product__c,
                       Pricebook2.Sales_Type__c,
                       Unit_of_Measure__c, Unit_Conversion_Factor__c
                FROM PricebookEntry
                WHERE IsActive = true
                  AND Product2.IsActive = true
                  AND Product2.SFA_Product__c = true
                  AND Pricebook2.IsActive = true
                  AND Pricebook2.Sales_Type__c IN ('Primary', 'Secondary')
                ORDER BY Product2.Name, Pricebook2.Name
                LIMIT :PRODUCT_LIMIT
            ]) {
                products.add(new Map<String, Object>{
                    'id' => entry.Id,
                    'productId' => entry.Product2Id,
                    'name' => entry.Product2.Name,
                    'productCode' => entry.Product2.ProductCode,
                    'description' => entry.Product2.Description,
                    'imageUrl' => entry.Product2.DisplayUrl,
                    'price' => entry.UnitPrice,
                    'pricebookName' => entry.Pricebook2.Name,
                    'salesType' => entry.Pricebook2.Sales_Type__c,
                    'unitOfMeasure' => entry.Unit_of_Measure__c,
                    'conversionFactor' => entry.Unit_Conversion_Factor__c
                });
            }

            List<Map<String, Object>> activeSchemes = new List<Map<String, Object>>();
            Date today = Date.today();
            for (String salesType : new List<String>{ 'Primary', 'Secondary' }) {
                for (Scheme_Product__c scheme : [
                    SELECT Id, Scheme__c, Scheme__r.Scheme_Name__c, Scheme__r.Scheme_Type__c,
                           Scheme__r.Sales_Type__c, Scheme__r.Active__c,
                           Scheme__r.Status__c, Scheme__r.Start_Date__c,
                           Scheme__r.End_Date__c, Product__c, Product__r.Name,
                           Minimum_Quantity__c, Minimum_Unit__c, Free_Quantity__c,
                           Free_Unit__c, Discount_Percentage__c, Discount_Amount__c,
                           Priority__c
                    FROM Scheme_Product__c
                    WHERE Active__c = true
                      AND Scheme__r.Active__c = true
                      AND Scheme__r.Status__c = 'Active'
                      AND Scheme__r.Sales_Type__c = :salesType
                      AND (Scheme__r.Start_Date__c = null
                           OR Scheme__r.Start_Date__c <= :today)
                      AND (Scheme__r.End_Date__c = null
                           OR Scheme__r.End_Date__c >= :today)
                    ORDER BY Priority__c DESC, Scheme__r.Scheme_Name__c
                    LIMIT 10
                ]) {
                    activeSchemes.add(new Map<String, Object>{
                        'id' => scheme.Scheme__c,
                        'schemeProductId' => scheme.Id,
                        'name' => scheme.Scheme__r.Scheme_Name__c,
                        'schemeType' => scheme.Scheme__r.Scheme_Type__c,
                        'salesType' => scheme.Scheme__r.Sales_Type__c,
                        'productId' => scheme.Product__c,
                        'productName' => scheme.Product__r == null
                            ? null
                            : scheme.Product__r.Name,
                        'minimumQuantity' => scheme.Minimum_Quantity__c,
                        'minimumUnit' => scheme.Minimum_Unit__c,
                        'freeQuantity' => scheme.Free_Quantity__c,
                        'freeUnit' => scheme.Free_Unit__c,
                        'discountPercentage' => scheme.Discount_Percentage__c,
                        'discountAmount' => scheme.Discount_Amount__c,
                        'priority' => scheme.Priority__c,
                        'startDate' => scheme.Scheme__r.Start_Date__c,
                        'endDate' => scheme.Scheme__r.End_Date__c
                    });
                }
            }

            Map<String, Object> distributorSummary = new Map<String, Object>{
                'id' => distributor.Id,
                'name' => distributor.Name,
                'accountNumber' => distributor.AccountNumber,
                'email' => distributor.Email__c,
                'phone' => distributor.Phone,
                'billingStreet' => distributor.BillingStreet,
                'billingCity' => distributor.BillingCity,
                'billingState' => distributor.BillingState,
                'billingPostalCode' => distributor.BillingPostalCode,
                'billingCountry' => distributor.BillingCountry,
                'status' => distributor.Login_Status__c
            };

            writeResponse(response, 200, new Map<String, Object>{
                'success' => true,
                'distributor' => distributorSummary,
                'summary' => new Map<String, Object>{
                    'totalOrders' => totalOrders,
                    'primaryOrders' => primaryOrders,
                    'secondaryOrders' => secondaryOrders,
                    'primarySalesValue' => primarySalesValue.setScale(2),
                    'secondarySalesValue' => secondarySalesValue.setScale(2),
                    'pendingPrimaryOrders' => pendingPrimaryOrders,
                    'pendingSecondaryOrders' => pendingSecondaryOrders,
                    'draftPrimaryOrders' => pendingPrimaryOrders,
                    'draftSecondaryOrders' => pendingSecondaryOrders,
                    'activePricedProducts' => activeProductCount,
                    'invoiceRecordCount' => invoiceRecordSummary.get('invoiceRecordCount'),
                    'availableInventoryPositionCount' => availableInventoryPositionCount,
                    'lowStockInventoryPositionCount' => lowStockInventoryPositionCount,
                    'lowStockProductCount' => lowStockProductCount,
                    'outstandingInvoiceAmount' => outstandingInvoiceAmount == null
                        ? 0
                        : outstandingInvoiceAmount,
                    'outstandingInvoiceCount' => invoiceSummary.get('invoiceCount'),
                    'pendingReturnCount' => pendingReturnCount
                },
                'orderStatuses' => orderStatuses,
                'recentOrders' => recentOrders,
                'recentInvoices' => recentInvoices,
                'products' => products,
                'activeSchemes' => activeSchemes,
                'beats' => beats,
                'outlets' => outlets
            });
        } catch (Exception error) {
            writeResponse(response, 500, new Map<String, Object>{
                'success' => false,
                'message' => 'The DMS dashboard could not be loaded. Please try again.'
            });
        }
    }

    @HttpDelete
    global static void logout() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        String token = getBearerToken();
        if (isValidToken(token)) {
            String tokenHash = hashToken(token);
            List<Account> accounts = [
                SELECT Id, DMS_Session_Token_Hash__c, DMS_Session_Expires_At__c
                FROM Account
                WHERE DMS_Session_Token_Hash__c = :tokenHash
                LIMIT 1
            ];
            if (!accounts.isEmpty()) {
                accounts[0].DMS_Session_Token_Hash__c = null;
                accounts[0].DMS_Session_Expires_At__c = null;
                update accounts[0];
            }
        }

        writeResponse(response, 200, new Map<String, Object>{ 'success' => true });
    }

    private static Account findDistributor(String token) {
        if (!isValidToken(token)) {
            return null;
        }

        String tokenHash = hashToken(token);
        Datetime currentTime = System.now();
        List<Account> accounts = [
            SELECT Id, Name, AccountNumber, Email__c, Phone,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   BillingCountry, Account_Category__c, Active__c, Login_Status__c,
                   DMS_Session_Expires_At__c
            FROM Account
            WHERE DMS_Session_Token_Hash__c = :tokenHash
              AND DMS_Session_Expires_At__c > :currentTime
              AND Account_Category__c LIKE '%Distributor%'
              AND Active__c = 'Yes'
              AND Login_Status__c = 'Active'
            LIMIT 1
        ];
        return accounts.isEmpty() ? null : accounts[0];
    }

    private static String getBearerToken() {
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

    private static Boolean isValidToken(String token) {
        return !String.isBlank(token)
            && token.length() == 64
            && Pattern.matches('^[a-fA-F0-9]{64}$', token);
    }

    private static String hashToken(String token) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
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
