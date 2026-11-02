public with sharing class DMSDistributorAccessService {
    public static Account getCurrentDistributor() {
        List<User> users = [
            SELECT Id, IsActive, Email, ContactId
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];

        if (users.isEmpty() || !users[0].IsActive || users[0].ContactId == null) {
            return null;
        }

        List<Contact> contacts = [
            SELECT AccountId
            FROM Contact
            WHERE Id = :users[0].ContactId
            LIMIT 1
        ];

        if (contacts.isEmpty() || contacts[0].AccountId == null) {
            return null;
        }

        List<Account> accounts = [
            SELECT Id, Name, Email__c, Account_Category__c, Active__c,
                   Login_Status__c, Must_Change_Password__c
            FROM Account
            WHERE Id = :contacts[0].AccountId
            LIMIT 1
        ];

        if (accounts.isEmpty() || !isEligibleDistributor(accounts[0])) {
            return null;
        }

        String userEmail = users[0].Email;
        String accountEmail = accounts[0].Email__c;
        if (String.isBlank(userEmail) || String.isBlank(accountEmail)
            || userEmail.trim().toLowerCase() != accountEmail.trim().toLowerCase()) {
            return null;
        }

        return accounts[0];
    }

    @TestVisible
    private static Boolean isEligibleDistributor(Account distributor) {
        return distributor != null
            && distributor.Account_Category__c == 'Distributor'
            && distributor.Active__c == 'Yes'
            && distributor.Login_Status__c == 'Active'
            && String.isNotBlank(distributor.Email__c);
    }
}
