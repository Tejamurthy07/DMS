public without sharing class DMSPaymentReceiptPdfController {
    public DMS_Payment_Receipt__c receipt { get; private set; }
    public DMS_Invoice__c invoice { get; private set; }
    public List<DMS_Invoice_Line__c> invoiceLines { get; private set; }

    public DMSPaymentReceiptPdfController() {
        invoiceLines = new List<DMS_Invoice_Line__c>();
        String receiptIdValue = ApexPages.currentPage().getParameters().get('id');
        String distributorIdValue =
            ApexPages.currentPage().getParameters().get('distributorId');
        String expiresAtValue = ApexPages.currentPage().getParameters().get('expiresAt');
        String providedSignature = ApexPages.currentPage().getParameters().get('signature');
        if (String.isBlank(receiptIdValue) || String.isBlank(distributorIdValue)
            || String.isBlank(expiresAtValue) || String.isBlank(providedSignature)) return;
        Id receiptId;
        Id distributorId;
        Long expiresAt;
        try {
            receiptId = (Id) receiptIdValue;
            distributorId = (Id) distributorIdValue;
            expiresAt = Long.valueOf(expiresAtValue);
        } catch (Exception error) {
            return;
        }
        Long currentTime = System.now().getTime();
        if (expiresAt == null || expiresAt <= currentTime
            || expiresAt > currentTime + 120000) return;

        Datetime nowValue = System.now();
        List<Account> distributors = [
            SELECT Id, DMS_Session_Token_Hash__c
            FROM Account
            WHERE Id = :distributorId
              AND DMS_Session_Expires_At__c > :nowValue
              AND Account_Category__c LIKE '%Distributor%'
              AND Active__c = 'Yes'
              AND Login_Status__c = 'Active'
            LIMIT 1
        ];
        if (distributors.isEmpty()
            || String.isBlank(distributors[0].DMS_Session_Token_Hash__c)) return;
        String signedValue = String.valueOf(receiptId) + '|' +
            String.valueOf(distributorId) + '|' + String.valueOf(expiresAt);
        String expectedSignature = EncodingUtil.convertToHex(Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(signedValue),
            Blob.valueOf(distributors[0].DMS_Session_Token_Hash__c)
        ));
        if (expectedSignature != providedSignature) return;

        List<DMS_Payment_Receipt__c> receipts = [
            SELECT Id, Name, Receipt_Date__c, Amount__c, Payment_Method__c,
                   Reference_Number__c, Notes__c, Balance_After_Receipt__c,
                   Invoice__c, Distributor__c
            FROM DMS_Payment_Receipt__c
            WHERE Id = :receiptId AND Distributor__c = :distributorId
            LIMIT 1
        ];
        if (receipts.isEmpty()) return;
        receipt = receipts[0];

        List<DMS_Invoice__c> invoices = [
            SELECT Id, Name, Invoice_Date__c, Invoice_Total__c, Credited_Amount__c,
                   Amount_Paid__c, Balance_Due__c, Retailer__r.Name,
                   Retailer__r.BillingStreet, Retailer__r.BillingCity,
                   Retailer__r.BillingState, Retailer__r.BillingPostalCode,
                   Retailer__r.BillingCountry, Distributor__r.Name,
                   Distributor__r.Phone, Distributor__r.BillingStreet,
                   Distributor__r.BillingCity, Distributor__r.BillingState,
                   Distributor__r.BillingPostalCode, Distributor__r.BillingCountry,
                   Secondary_Order__r.OrderNumber
            FROM DMS_Invoice__c
            WHERE Id = :receipt.Invoice__c
            LIMIT 1
        ];
        if (invoices.isEmpty()) return;
        invoice = invoices[0];
        invoiceLines = [
            SELECT Product__r.Name, Quantity__c, Unit_of_Measure__c, Unit_Price__c,
                   Gross_Amount__c, Discount_Amount__c, Taxable_Amount__c,
                   Tax_Rate__c, Tax_Amount__c, Line_Total__c
            FROM DMS_Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
            ORDER BY CreatedDate, Id
        ];
    }
}
