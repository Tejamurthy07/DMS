public with sharing class DistributorCredentialController {

    /*
     * Retrieve Distributor Accounts.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> getDistributors() {

        try {
            return [
                SELECT Id,
                       Name,
                       Email__c,
                       Contact_Number__c,
                       Account_Category__c,
                       Active__c,
                       Login_Status__c,
                       Must_Change_Password__c
                FROM Account
                WHERE Account_Category__c = 'Distributor'
                WITH USER_MODE
                ORDER BY Name
            ];

        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'Error retrieving distributors: ' + ex.getMessage()
            );

            throw new AuraHandledException(
                'Unable to retrieve distributors. Check your Account permissions.'
            );
        }
    }


    /*
     * Activate or deactivate a distributor.
     */
    @AuraEnabled
    public static void updateDistributorStatus(
        Id accountId,
        Boolean shouldActivate
    ) {

        if (accountId == null) {
            throw new AuraHandledException(
                'Distributor Account ID is required.'
            );
        }

        if (shouldActivate == null) {
            throw new AuraHandledException(
                'Please specify whether to activate or deactivate the distributor.'
            );
        }

        List<Account> accounts;

        try {
            accounts = [
                SELECT Id,
                       Name,
                       Account_Category__c,
                       Active__c,
                       Login_Status__c,
                       Must_Change_Password__c,
                       Activation_Token_Hash__c,
                       Activation_Token_Expiry__c
                FROM Account
                WHERE Id = :accountId
                AND Account_Category__c = 'Distributor'
                WITH USER_MODE
                LIMIT 1
            ];

        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'Error finding distributor: ' + ex.getMessage()
            );

            throw new AuraHandledException(
                'Unable to find the distributor. Check your permissions.'
            );
        }

        if (accounts.isEmpty()) {
            throw new AuraHandledException(
                'Distributor Account was not found.'
            );
        }

        Account distributor = accounts[0];

        if (shouldActivate) {

            distributor.Active__c = 'Yes';
            distributor.Login_Status__c = 'Pending';
            distributor.Must_Change_Password__c = true;

        } else {

            distributor.Active__c = 'No';
            distributor.Login_Status__c = 'Inactive';
            distributor.Must_Change_Password__c = true;

            // Invalidate any outstanding activation link.
            distributor.Activation_Token_Hash__c = null;
            distributor.Activation_Token_Expiry__c = null;
        }

        try {
            update as user distributor;

        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'Error updating distributor status: ' + ex.getMessage()
            );

            throw new AuraHandledException(
                'Unable to update distributor status. Check your field permissions and picklist values.'
            );
        }
    }


    /*
     * Send an activation email to a distributor.
     *
     * The activation token is stored as a SHA-256 hash.
     * The raw token is sent only in the activation URL.
     */
    @AuraEnabled
    public static String sendDistributorCredentials(Id accountId) {

        if (accountId == null) {
            throw new AuraHandledException(
                'Distributor Account ID is required.'
            );
        }

        List<Account> accounts;

        try {
            accounts = [
                SELECT Id,
                       Name,
                       Email__c,
                	   Phone,
                       Account_Category__c,
                       Active__c,
                       Login_Status__c,
                       Must_Change_Password__c,
                       Activation_Token_Hash__c,
                       Activation_Token_Expiry__c
                FROM Account
                WHERE Id = :accountId
                AND Account_Category__c = 'Distributor'
                WITH USER_MODE
                LIMIT 1
            ];

        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                'Error finding distributor: ' + ex.getMessage()
            );

            throw new AuraHandledException(
                'Unable to find the distributor. Check your permissions.'
            );
        }

        if (accounts.isEmpty()) {
            throw new AuraHandledException(
                'Distributor Account was not found.'
            );
        }

        Account distributor = accounts[0];

        if (distributor.Active__c != 'Yes') {
            throw new AuraHandledException(
                'Activate the distributor Account before sending an activation email.'
            );
        }

        if (String.isBlank(distributor.Email__c)) {
            throw new AuraHandledException(
                'Please enter an email address in the distributor Account.'
            );
        }

        /*
         * Generate a cryptographically random token.
         */
        String activationToken =
            EncodingUtil.convertToHex(
                Crypto.generateAesKey(256)
            );

        String tokenHash =
            EncodingUtil.convertToHex(
                Crypto.generateDigest(
                    'SHA-256',
                    Blob.valueOf(activationToken)
                )
            );

        Datetime expiryTime = Datetime.now().addMinutes(30);

        String activationBaseUrl =
            'http://localhost:5173/reset-password';

        String activationLink =
            activationBaseUrl +
            '?token=' +
            EncodingUtil.urlEncode(
                activationToken,
                'UTF-8'
            );

        Messaging.SingleEmailMessage email =
            new Messaging.SingleEmailMessage();

        email.setToAddresses(
            new String[] { distributor.Email__c }
        );

        email.setSubject(
            'Activate Your Distributor Management Account'
        );

        email.setPlainTextBody(
            'Hello ' + distributor.Name + ',\n\n' +
            'Your Distributor Management System account is ready for activation.\n\n' +
            'Username: ' + distributor.Email__c + '\n\n' +
            'Please open the following link to set your password:\n\n' +
            activationLink + '\n\n' +
            'This link expires in 30 minutes and is intended for one-time use.\n\n' +
            'If you did not request this email, please contact your administrator.\n\n' +
            'Regards,\n' +
            'Distributor Management System'
        );

        email.setSaveAsActivity(false);

        /*
         * Save the token hash and expiry before sending the email.
         * If the send operation fails, the transaction should be
         * allowed to roll back. Verify this behavior in your org.
         */
        distributor.Activation_Token_Hash__c = tokenHash;
        distributor.Activation_Token_Expiry__c = expiryTime;
        distributor.Login_Status__c = 'Pending';
        distributor.Must_Change_Password__c = true;

        try {

            update as user distributor;

            Messaging.SendEmailResult[] results =
                Messaging.sendEmail(
                    new Messaging.SingleEmailMessage[] { email },
                    false
                );

            if (
                results.isEmpty() ||
                !results[0].isSuccess()
            ) {

                String errorMessage =
                    'Unable to send the activation email. Check Salesforce email configuration.';

                if (
                    !results.isEmpty() &&
                    !results[0].getErrors().isEmpty()
                ) {
                    errorMessage =
                        results[0].getErrors()[0].getMessage();
                }

                throw new AuraHandledException(
                    errorMessage
                );
            }

        } catch (AuraHandledException ex) {
            throw ex;

        } catch (Exception ex) {

            System.debug(
                LoggingLevel.ERROR,
                'Distributor activation error: ' + ex.getMessage()
            );

            throw new AuraHandledException(
                'Unable to process distributor activation. Please try again.'
            );
        }

        return 'Activation email sent to ' +
            distributor.Email__c +
            '. The activation link expires in 30 minutes.';
    }
}