@IsTest
private class DMSCompanyPrimaryWorkflowResourceTest {
    @TestSetup
    static void createCompanyOperator() {
        PermissionSet companyAccess = [
            SELECT Id FROM PermissionSet
            WHERE Name = 'DMS_Company_Inventory_Access'
            LIMIT 1
        ];
        User companyUser = new User(
            Alias = 'dmscomp',
            Email = 'company-workflow-test@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Company Workflow Test',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = companyTestUsername()
        );
        insert companyUser;
        insert new PermissionSetAssignment(
            AssigneeId = companyUser.Id,
            PermissionSetId = companyAccess.Id
        );
    }

    @IsTest
    static void companyOperationsRequireCompanyPermission() {
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf('{"action":"confirmDispatch"}');

        DMSCompanyPrimaryWorkflowResource.postCompanyAction();

        System.assertEquals(403, RestContext.response.statusCode);
        System.assert(
            RestContext.response.responseBody.toString().contains('not authorized')
        );
    }

    @IsTest
    static void companyInventoryShowsOnlyCompanyWarehouseBalances() {
        User currentUser = [
            SELECT Id FROM User WHERE Username = :companyTestUsername() LIMIT 1
        ];
        System.runAs(currentUser) {
            Account distributor = new Account(Name = 'Company Inventory Scope Distributor');
            insert distributor;
            Warehouse__c companyWarehouse = new Warehouse__c(
                Name = 'Company Inventory Scope Warehouse',
                Warehouse_Type__c = 'Company Warehouse',
                Warehouse_Status__c = 'Active'
            );
            Warehouse__c distributorWarehouse = new Warehouse__c(
                Name = 'Distributor Inventory Scope Warehouse',
                Warehouse_Type__c = 'Distributor Warehouse',
                Distributor__c = distributor.Id,
                Warehouse_Status__c = 'Active'
            );
            insert new List<Warehouse__c>{companyWarehouse, distributorWarehouse};

            Product2 companyProduct = new Product2(
                Name = 'Company Inventory Scope Product',
                IsActive = true
            );
            Product2 distributorProduct = new Product2(
                Name = 'Distributor Inventory Scope Product',
                IsActive = true
            );
            insert new List<Product2>{companyProduct, distributorProduct};
            insert new List<Inventory__c>{
                new Inventory__c(
                    Warehouse__c = companyWarehouse.Id,
                    Product__c = companyProduct.Id,
                    Available_Quantity__c = 15,
                    Reserved_Quantity__c = 2,
                    Minimum_Stock_Level__c = 1
                ),
                new Inventory__c(
                    Warehouse__c = distributorWarehouse.Id,
                    Product__c = distributorProduct.Id,
                    Available_Quantity__c = 100,
                    Reserved_Quantity__c = 0,
                    Minimum_Stock_Level__c = 1
                )
            };
            RestContext.request = new RestRequest();
            RestContext.response = new RestResponse();

            DMSCompanyPrimaryWorkflowResource.getCompanyInventory();

            String responseBody = RestContext.response.responseBody.toString();
            System.assertEquals(200, RestContext.response.statusCode);
            System.assert(responseBody.contains('Company Inventory Scope Product'));
            System.assert(responseBody.contains('Company Inventory Scope Warehouse'));
            System.assert(!responseBody.contains('Distributor Inventory Scope Product'));
            System.assert(!responseBody.contains('Distributor Inventory Scope Warehouse'));
            Map<String, Object> response =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> warehouses = (List<Object>) response.get('warehouses');
            System.assertEquals(1, warehouses.size());
            System.assertEquals(
                companyWarehouse.Id,
                ((Map<String, Object>) warehouses[0]).get('id')
            );
        }
    }

    private static String companyTestUsername() {
        return 'company.workflow.' + UserInfo.getOrganizationId() + '@example.invalid';
    }
}
