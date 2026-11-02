@IsTest
private class DMSBarcodeTransactionValidationTest {
    private static final String TOKEN =
        'abababababababababababababababababababababababababababababababab';

    @IsTest
    static void secondaryDispatchBarcodeValidationRejectsInvalidInput() {
        createDistributor();
        setRequest(TOKEN, '{"action":"validateDispatchBarcode","barcode":"BAR","proposedQuantity":1}');

        DMSFulfillmentResource.postFulfillmentAction();

        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            RestContext.response.responseBody.toString().contains('invoice')
        );
    }

    @IsTest
    static void receiptBarcodeValidationRejectsInvalidInput() {
        createDistributor();
        setRequest(TOKEN, '{"action":"validateReceiptBarcode","barcode":"BAR","proposedQuantity":1}');

        DMSDistributorInventoryResource.postInventoryAction();

        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            RestContext.response.responseBody.toString().contains('order')
        );
    }

    @IsTest
    static void returnBarcodeValidationRejectsInvalidInput() {
        createDistributor();
        setRequest(TOKEN, '{"action":"validateReturnBarcode","barcode":"BAR","proposedQuantity":1}');

        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            RestContext.response.responseBody.toString().contains('invoice')
        );
    }

    private static Account createDistributor() {
        Account distributor = new Account(
            Name = 'Barcode Transaction Validation Distributor',
            Email__c = 'barcode-validation@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            DMS_Session_Token_Hash__c = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(TOKEN))
            ),
            DMS_Session_Expires_At__c = System.now().addHours(1)
        );
        insert distributor;
        return distributor;
    }

    private static void setRequest(String token, String payload) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = 'POST';
        RestContext.request.headers.put('x-dms-session', token);
        RestContext.request.requestBody = Blob.valueOf(payload);
        RestContext.response = new RestResponse();
    }
}
