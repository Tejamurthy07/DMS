public without sharing class DMSDistributorSessionAccessService {
    public static Account findDistributor(String token) {
        if (String.isBlank(token) || token.length() != 64
            || !Pattern.matches('^[a-fA-F0-9]{64}$', token)) {
            return null;
        }

        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
        Datetime currentTime = System.now();
        List<Account> distributors = [
            SELECT Id
            FROM Account
            WHERE DMS_Session_Token_Hash__c = :tokenHash
              AND DMS_Session_Expires_At__c > :currentTime
              AND Account_Category__c LIKE '%Distributor%'
              AND Active__c = 'Yes'
              AND Login_Status__c = 'Active'
            LIMIT 1
        ];
        return distributors.isEmpty() ? null : distributors[0];
    }
}
