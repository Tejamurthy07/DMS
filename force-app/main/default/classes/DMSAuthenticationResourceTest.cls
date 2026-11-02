@IsTest
private class DMSAuthenticationResourceTest {
    @IsTest
    static void loginReturnsTheFrontendSessionShape() {
        String password = 'ValidDistributor123!';
        insert new Account(
            Name = 'DMS Store Sharing Login Email',
            Email__c = 'login-test@example.invalid',
            Active__c = 'Yes'
        );
        Account distributor = new Account(
            Name = 'DMS Login Test Distributor',
            Email__c = 'login-test@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            Password_Hash__c = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(password))
            ),
            Must_Change_Password__c = false
        );
        insert distributor;

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, String>{
            'email' => distributor.Email__c,
            'password' => password
        }));
        RestContext.response = new RestResponse();

        Test.startTest();
        DMSAuthResource.doPost();
        Test.stopTest();

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, result.get('success'));
        System.assertEquals(result.get('token'), result.get('accessToken'));
        System.assertNotEquals(null, result.get('expiresAt'));
        Map<String, Object> user = (Map<String, Object>) result.get('user');
        System.assertEquals(distributor.Id, user.get('id'));
        System.assertEquals(distributor.Email__c, user.get('email'));
        System.assertEquals(false, user.get('mustChangePassword'));
        Account authenticated = [
            SELECT DMS_Session_Token_Hash__c, DMS_Session_Expires_At__c
            FROM Account
            WHERE Id = :distributor.Id
        ];
        System.assertEquals(
            EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf((String) result.get('token')))
            ),
            authenticated.DMS_Session_Token_Hash__c
        );
        System.assert(authenticated.DMS_Session_Expires_At__c > System.now());
    }

    @IsTest
    static void loginRejectsMissingCredentials() {
        Map<String, Object> result = DMSLoginController.login('', null);
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Email and password are required.', result.get('message'));
    }

    @IsTest
    static void loginRejectsIncorrectPassword() {
        Account distributor = createLoginDistributor(
            'wrong-password@example.invalid',
            'Wrong Password Distributor',
            'CorrectPassword123!'
        );

        Map<String, Object> result = DMSLoginController.login(
            distributor.Email__c,
            'IncorrectPassword123!'
        );
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Invalid email or password.', result.get('message'));
    }

    @IsTest
    static void loginRejectsAmbiguousDistributorAccounts() {
        String email = 'ambiguous-login@example.invalid';
        createLoginDistributor(email, 'Ambiguous Distributor One', 'ValidPassword123!');
        createLoginDistributor(email, 'Ambiguous Distributor Two', 'ValidPassword123!');

        Map<String, Object> result = DMSLoginController.login(email, 'ValidPassword123!');
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Invalid email or password.', result.get('message'));
    }

    @IsTest
    static void loginAcceptsAnUnexpiredTemporaryPassword() {
        String password = 'TemporaryPassword123!';
        Account distributor = createLoginDistributor(
            'temporary-login@example.invalid',
            'Temporary Password Distributor',
            'OriginalPassword123!'
        );
        distributor.Must_Change_Password__c = true;
        distributor.Temporary_Password_Hash__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(password))
        );
        distributor.Temporary_Password_Expiry__c = System.now().addMinutes(30);
        update distributor;

        Map<String, Object> result = DMSLoginController.login(distributor.Email__c, password);
        System.assertEquals(true, result.get('success'));
        Map<String, Object> user = (Map<String, Object>) result.get('user');
        System.assertEquals(true, user.get('mustChangePassword'));
    }

    @IsTest
    static void loginNormalizesEmailWhitespaceAndCase() {
        String password = 'NormalizedPassword123!';
        Account distributor = createLoginDistributor(
            'normalized-login@example.invalid',
            'Normalized Email Distributor',
            password
        );

        Map<String, Object> result = DMSLoginController.login(
            '  NORMALIZED-LOGIN@EXAMPLE.INVALID ',
            password
        );
        System.assertEquals(true, result.get('success'));
    }

    @IsTest
    static void loginAcceptsTemporaryPasswordWithoutExpiry() {
        String password = 'NoExpiryTemporary123!';
        Account distributor = createLoginDistributor(
            'no-expiry-login@example.invalid',
            'No Expiry Distributor',
            'OriginalPassword123!'
        );
        distributor.Must_Change_Password__c = true;
        distributor.Temporary_Password_Hash__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(password))
        );
        distributor.Temporary_Password_Expiry__c = null;
        update distributor;

        Map<String, Object> result = DMSLoginController.login(distributor.Email__c, password);
        System.assertEquals(true, result.get('success'));
    }

    @IsTest
    static void loginRejectsAnExpiredTemporaryPassword() {
        String password = 'ExpiredTemporary123!';
        Account distributor = createLoginDistributor(
            'expired-login@example.invalid',
            'Expired Password Distributor',
            'OriginalPassword123!'
        );
        distributor.Must_Change_Password__c = true;
        distributor.Temporary_Password_Hash__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(password))
        );
        distributor.Temporary_Password_Expiry__c = System.now().addMinutes(-1);
        update distributor;

        Map<String, Object> result = DMSLoginController.login(distributor.Email__c, password);
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Invalid email or password.', result.get('message'));
    }

    @IsTest
    static void loginRejectsDistributorWithoutPasswordHash() {
        Account distributor = createLoginDistributor(
            'missing-hash@example.invalid',
            'Missing Hash Distributor',
            null
        );

        Map<String, Object> result = DMSLoginController.login(
            distributor.Email__c,
            'AnyPassword123!'
        );
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Invalid email or password.', result.get('message'));
    }

    @IsTest
    static void loginRequiresTemporaryPasswordWhenPasswordChangeIsPending() {
        Account distributor = createLoginDistributor(
            'missing-temporary@example.invalid',
            'Missing Temporary Password Distributor',
            'OriginalPassword123!'
        );
        distributor.Must_Change_Password__c = true;
        distributor.Temporary_Password_Hash__c = null;
        update distributor;

        Map<String, Object> result = DMSLoginController.login(
            distributor.Email__c,
            'OriginalPassword123!'
        );
        System.assertEquals(false, result.get('success'));
        System.assertEquals('Password change required.', result.get('message'));
    }

    @IsTest
    static void onlyActiveDistributorAccountsAreEligible() {
        Account eligibleAccount = new Account(
            Name = 'DMS Test Distributor',
            Email__c = 'distributor@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active'
        );
        Account inactiveAccount = new Account(
            Name = 'DMS Inactive Distributor',
            Email__c = 'inactive@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'No',
            Login_Status__c = 'Inactive'
        );
        Account outletAccount = new Account(
            Name = 'DMS Test Outlet',
            Email__c = 'outlet@example.invalid',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Login_Status__c = 'Active'
        );

        System.assertEquals(
            true,
            DMSDistributorAccessService.isEligibleDistributor(eligibleAccount)
        );
        System.assertEquals(
            false,
            DMSDistributorAccessService.isEligibleDistributor(inactiveAccount)
        );
        System.assertEquals(
            false,
            DMSDistributorAccessService.isEligibleDistributor(outletAccount)
        );
        System.assertEquals(
            false,
            DMSDistributorAccessService.isEligibleDistributor(null)
        );
    }

    @IsTest
    static void sessionRequiresLinkedEligibleDistributor() {
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();

        Test.startTest();
        DMSDistributorSessionResource.getSession();
        Test.stopTest();

        System.assertEquals(403, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('"success":false'));
    }

    @IsTest
    static void passwordChangeRejectsMissingFields() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf('{}');
        RestContext.response = new RestResponse();

        Test.startTest();
        DMSChangePasswordResource.changePassword();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void passwordChangeRejectsMismatchedConfirmation() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(
            '{"currentPassword":"current","newPassword":"NewPassword123!","confirmNewPassword":"DifferentPassword123!"}'
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        DMSChangePasswordResource.changePassword();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
        System.assert(
            RestContext.response.responseBody.toString().contains('do not match')
        );
    }

    @IsTest
    static void activationTokenSetsPasswordAndCanOnlyBeUsedOnce() {
        String activationToken = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        String newPassword = 'ActivationValid123!';
        String tokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(activationToken))
        );
        Account distributor = new Account(
            Name = 'DMS Activation Distributor',
            Email__c = 'activation@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Pending',
            Must_Change_Password__c = true,
            Activation_Token_Hash__c = tokenHash,
            Activation_Token_Expiry__c = System.now().addMinutes(30)
        );
        insert distributor;

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'token' => activationToken,
            'password' => newPassword,
            'confirmPassword' => newPassword
        }));
        RestContext.response = new RestResponse();

        Test.startTest();
        DMSDistributorActivationResource.setPassword();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Account activated = [
            SELECT Password_Hash__c, Login_Status__c, Must_Change_Password__c,
                   Activation_Token_Hash__c, Activation_Token_Expiry__c
            FROM Account
            WHERE Id = :distributor.Id
        ];
        System.assertEquals('Active', activated.Login_Status__c);
        System.assertEquals(false, activated.Must_Change_Password__c);
        System.assertEquals(
            EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(newPassword))
            ),
            activated.Password_Hash__c
        );
        System.assertEquals(null, activated.Activation_Token_Hash__c);
        System.assertEquals(null, activated.Activation_Token_Expiry__c);

        RestContext.response = new RestResponse();
        DMSDistributorActivationResource.setPassword();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    private static Account createLoginDistributor(String email, String name, String password) {
        Account distributor = new Account(
            Name = name,
            Email__c = email,
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            Password_Hash__c = String.isBlank(password)
                ? null
                : EncodingUtil.convertToHex(
                    Crypto.generateDigest('SHA-256', Blob.valueOf(password))
                ),
            Must_Change_Password__c = false
        );
        insert distributor;
        return distributor;
    }
}
