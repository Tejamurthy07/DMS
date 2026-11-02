@RestResource(urlMapping='/dms/v1/reset-password')
global without sharing class DMSDistributorActivationResource {
    @HttpPost
    global static void setPassword() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        Map<String, Object> requestData;
        try {
            if (RestContext.request == null || RestContext.request.requestBody == null
                || String.isBlank(RestContext.request.requestBody.toString())) {
                writeResponse(response, 400, false, 'Request body is required.');
                return;
            }
            requestData = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
        } catch (Exception ex) {
            writeResponse(response, 400, false, 'Request body must be valid JSON.');
            return;
        }

        String token = getString(requestData, 'token');
        String password = getString(requestData, 'password');
        String confirmPassword = getString(requestData, 'confirmPassword');
        if (String.isBlank(token) || String.isBlank(password) || String.isBlank(confirmPassword)) {
            writeResponse(response, 400, false, 'Complete all password reset fields.');
            return;
        }
        if (token.length() != 64 || !Pattern.matches('^[a-fA-F0-9]{64}$', token)) {
            writeResponse(response, 400, false, 'This activation link is invalid or has expired.');
            return;
        }
        if (password != confirmPassword) {
            writeResponse(response, 400, false, 'The new password and confirmation do not match.');
            return;
        }
        if (!isPasswordPolicySatisfied(password)) {
            writeResponse(
                response,
                400,
                false,
                'Use 12–128 characters with uppercase, lowercase, a number, and a symbol.'
            );
            return;
        }

        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(token))
        );
        Datetime currentTime = System.now();
        List<Account> accounts = [
            SELECT Id, Account_Category__c, Active__c, Login_Status__c,
                   Must_Change_Password__c, Password_Hash__c,
                   Temporary_Password_Hash__c, Temporary_Password_Expiry__c,
                   Activation_Token_Hash__c, Activation_Token_Expiry__c
            FROM Account
            WHERE Activation_Token_Hash__c = :tokenHash
              AND Activation_Token_Expiry__c > :currentTime
            LIMIT 1
            FOR UPDATE
        ];
        if (accounts.isEmpty()) {
            writeResponse(response, 400, false, 'This activation link is invalid or has expired.');
            return;
        }

        Account distributor = accounts[0];
        if (distributor.Account_Category__c != 'Distributor' || distributor.Active__c != 'Yes') {
            writeResponse(response, 400, false, 'This activation link is invalid or has expired.');
            return;
        }

        distributor.Password_Hash__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(password))
        );
        distributor.Temporary_Password_Hash__c = null;
        distributor.Temporary_Password_Expiry__c = null;
        distributor.Must_Change_Password__c = false;
        distributor.Login_Status__c = 'Active';
        distributor.Activation_Token_Hash__c = null;
        distributor.Activation_Token_Expiry__c = null;
        update distributor;

        writeResponse(response, 200, true, 'Password set. Sign in with your new password.');
    }

    private static String getString(Map<String, Object> data, String key) {
        if (data == null || !data.containsKey(key) || data.get(key) == null) {
            return null;
        }
        Object value = data.get(key);
        return value instanceof String ? (String) value : String.valueOf(value);
    }

    private static Boolean isPasswordPolicySatisfied(String password) {
        return password.length() >= 12
            && password.length() <= 128
            && Pattern.matches('(?s).*[A-Z].*', password)
            && Pattern.matches('(?s).*[a-z].*', password)
            && Pattern.matches('(?s).*\\d.*', password)
            && Pattern.matches('(?s).*[^A-Za-z0-9].*', password);
    }

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Boolean success,
        String message
    ) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => success,
            'message' => message
        }));
    }
}
