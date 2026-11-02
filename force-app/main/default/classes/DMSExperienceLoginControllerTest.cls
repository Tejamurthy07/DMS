@IsTest
private class DMSExperienceLoginControllerTest {
    @IsTest
    static void loginRequiresCredentials() {
        Test.setCurrentPage(new PageReference('/apex/DMSLogin'));
        DMSExperienceLoginController controller = new DMSExperienceLoginController();

        System.assertEquals(null, controller.login());
        System.assertEquals(
            'Enter your username and password to continue.',
            controller.errorMessage
        );
    }

    @IsTest
    static void loginRejectsExternalRedirect() {
        Test.setCurrentPage(new PageReference('/apex/DMSLogin'));
        ApexPages.currentPage().getParameters().put('startURL', 'https://example.invalid/');
        DMSExperienceLoginController controller = new DMSExperienceLoginController();
        controller.username = 'distributor@example.invalid';
        controller.setPassword('not-a-real-password');

        System.assertEquals(null, controller.login());
        System.assertEquals(
            'Sign-in could not be completed. Please try again.',
            controller.errorMessage
        );
    }

    @IsTest
    static void safeStartUrlUsesLocalPathsOnly() {
        System.assertEquals('/', DMSExperienceLoginController.safeStartUrl(null));
        System.assertEquals(
            '/services/oauth2/authorize?response_type=code',
            DMSExperienceLoginController.safeStartUrl('/services/oauth2/authorize?response_type=code')
        );
        System.assertEquals(null, DMSExperienceLoginController.safeStartUrl('//example.invalid/'));
        System.assertEquals(null, DMSExperienceLoginController.safeStartUrl('/\\example.invalid/'));
    }
}