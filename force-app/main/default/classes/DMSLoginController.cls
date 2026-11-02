global inherited sharing class DMSLoginController {
    @AuraEnabled
    public static Map<String, Object> login(String email, String password) {
        return performLogin(email, password);
    }

    private static Map<String, Object> performLogin(String email, String password) {
        Map<String, Object> response = new Map<String, Object>();

        try {
            String normalizedEmail = normalizeEmail(email);
            String normalizedPassword = String.isBlank(password) ? '' : password;

            if (String.isBlank(normalizedEmail) || String.isBlank(normalizedPassword)) {
                response.put('success', false);
                response.put('message', 'Email and password are required.');
                return response;
            }

            List<Account> accountMatches = [
                SELECT Id, Name, Email__c, Account_Category__c, Active__c, Login_Status__c,
                       Password_Hash__c, Must_Change_Password__c, Temporary_Password_Hash__c,
                       Temporary_Password_Expiry__c, Last_Login__c
                FROM Account
                WHERE Email__c = :normalizedEmail
                  AND Account_Category__c LIKE '%Distributor%'
                  AND Active__c = 'Yes'
                  AND Login_Status__c = 'Active'
                LIMIT 2
            ];

            if (accountMatches.size() != 1) {
                response.put('success', false);
                response.put('message', 'Invalid email or password.');
                return response;
            }

            Account distributor = accountMatches[0];

            if (String.isBlank(distributor.Account_Category__c) || !distributor.Account_Category__c.containsIgnoreCase('Distributor')) {
                response.put('success', false);
                response.put('message', 'Invalid email or password.');
                return response;
            }

            if (!coerceBoolean(distributor.get('Active__c'))) {
                response.put('success', false);
                response.put('message', 'This account is inactive.');
                return response;
            }

            String loginStatus = distributor.Login_Status__c;
            if (loginStatus == 'Locked') {
                response.put('success', false);
                response.put('message', 'This account is temporarily locked.');
                return response;
            }

            if (loginStatus == 'Pending') {
                response.put('success', false);
                response.put('message', 'Your account is pending activation.');
                return response;
            }

            if (String.isBlank(distributor.Password_Hash__c)) {
                response.put('success', false);
                response.put('message', 'Invalid email or password.');
                return response;
            }

            Boolean mustChangePassword = coerceBoolean(distributor.get('Must_Change_Password__c'));
            if (mustChangePassword && String.isBlank(distributor.Temporary_Password_Hash__c)) {
                response.put('success', false);
                response.put('message', 'Password change required.');
                return response;
            }

            Boolean passwordMatches = verifyPassword(
                normalizedPassword,
                distributor.Password_Hash__c,
                distributor.Temporary_Password_Hash__c,
                mustChangePassword,
                distributor.Temporary_Password_Expiry__c
            );
            if (!passwordMatches) {
                response.put('success', false);
                response.put('message', 'Invalid email or password.');
                return response;
            }

            String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
            Datetime expiresAt = System.now().addHours(8);
            distributor.DMS_Session_Token_Hash__c = makeHash(token);
            distributor.DMS_Session_Expires_At__c = expiresAt;

            response.put('success', true);
            response.put('token', token);
            response.put('expiresAt', expiresAt);
            response.put('user', new Map<String, Object>{
                'id' => distributor.Id,
                'name' => distributor.Name,
                'email' => distributor.Email__c,
                'mustChangePassword' => mustChangePassword
            });

            distributor.Last_Login__c = System.now();
            update distributor;

            return response;
        } catch (Exception ex) {
            response.put('success', false);
            response.put('message', 'Unable to authenticate at this time.');
            return response;
        }
    }

    private static Boolean coerceBoolean(Object value) {
        if (value == null) {
            return false;
        }

        if (value instanceof Boolean) {
            return (Boolean) value;
        }

        if (value instanceof String) {
            String normalizedValue = ((String) value).trim();
            return normalizedValue.equalsIgnoreCase('true')
                || normalizedValue.equalsIgnoreCase('yes');
        }

        if (value instanceof Integer) {
            return (Integer) value != 0;
        }

        if (value instanceof Decimal) {
            return ((Decimal) value) != 0;
        }

        return false;
    }

    private static Boolean verifyPassword(
        String inputPassword,
        String currentHash,
        String temporaryHash,
        Boolean mustChangePassword,
        DateTime temporaryExpiry
    ) {
        String effectiveHash = currentHash;

        if (mustChangePassword && String.isNotBlank(temporaryHash)) {
            if (temporaryExpiry != null && temporaryExpiry < System.now()) {
                return false;
            }
            effectiveHash = temporaryHash;
        }

        if (String.isBlank(inputPassword) || String.isBlank(effectiveHash)) {
            return false;
        }

        return hashMatches(inputPassword, effectiveHash);
    }

    private static Boolean hashMatches(String plainText, String storedHash) {
        try {
            String inputHash = makeHash(plainText);
            return String.valueOf(inputHash).equalsIgnoreCase(String.valueOf(storedHash));
        } catch (Exception ex) {
            return false;
        }
    }

    private static String makeHash(String plainText) {
        Blob data = Blob.valueOf(plainText);
        Blob digest = Crypto.generateDigest('SHA-256', data);
        return EncodingUtil.convertToHex(digest);
    }

    private static String normalizeEmail(String rawEmail) {
        if (String.isBlank(rawEmail)) {
            return '';
        }
        return rawEmail.trim().toLowerCase();
    }
}