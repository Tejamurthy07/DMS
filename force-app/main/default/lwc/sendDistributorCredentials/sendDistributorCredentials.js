import { LightningElement, wire } from 'lwc';

import getDistributors
    from '@salesforce/apex/DistributorCredentialController.getDistributors';

import updateDistributorStatus
    from '@salesforce/apex/DistributorCredentialController.updateDistributorStatus';

import sendDistributorCredentials
    from '@salesforce/apex/DistributorCredentialController.sendDistributorCredentials';

import { refreshApex } from '@salesforce/apex';

import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SendDistributorCrendentials extends LightningElement {

    distributors = [];
    searchTerm = '';
    isLoading = true;
    errorMessage = '';

    wiredDistributorsResult;

    showConfirmation = false;
    selectedDistributorId;
    selectedDistributorName;
    selectedActiveValue;

    /*
     * Load distributor Accounts.
     */
    @wire(getDistributors)
    wiredDistributors(result) {

        this.wiredDistributorsResult = result;

        const { data, error } = result;

        if (data) {

            this.distributors = data.map((record) => {

                const isActive = this.isAccountActive(
                    record.Active__c
                );

                const loginStatus =
                    record.Login_Status__c || 'Pending';

                return {
                    ...record,

                    isActive,

                    initials: this.getInitials(record.Name),

                    recordUrl: '/' + record.Id,

                    accountStatusClass: isActive
                        ? 'status-badge status-active'
                        : 'status-badge status-inactive',

                    loginStatusClass:
                        this.getLoginStatusClass(loginStatus),

                    toggleButtonLabel: isActive
                        ? 'Deactivate'
                        : 'Activate',

                    toggleButtonClass: isActive
                        ? 'deactivate-button'
                        : 'activate-button',

                    sendDisabled: !isActive
                };
            });

            this.errorMessage = '';
            this.isLoading = false;

        } else if (error) {

            this.distributors = [];
            this.errorMessage = this.getErrorMessage(error);
            this.isLoading = false;
        }
    }

    /*
     * Check Account active value.
     */
    isAccountActive(value) {

        if (value === null || value === undefined) {
            return false;
        }

        return ![
            'No',
            'Inactive',
            'False',
            ''
        ].includes(
            String(value).trim()
        );
    }

    /*
     * Generate initials for the avatar.
     */
    getInitials(name) {

        if (!name) {
            return 'D';
        }

        const words = name.trim().split(/\s+/);

        if (words.length === 1) {
            return words[0]
                .substring(0, 2)
                .toUpperCase();
        }

        return (
            words[0].charAt(0) +
            words[words.length - 1].charAt(0)
        ).toUpperCase();
    }

    /*
     * Style login status badges.
     */
    getLoginStatusClass(status) {

        switch (status) {

            case 'Active':
                return 'login-badge login-active';

            case 'Pending':
                return 'login-badge login-pending';

            case 'Locked':
                return 'login-badge login-locked';

            case 'Inactive':
                return 'login-badge login-inactive';

            default:
                return 'login-badge login-pending';
        }
    }

    /*
     * Summary card values.
     */
    get totalDistributors() {
        return this.distributors.length;
    }

    get activeDistributors() {

        return this.distributors.filter(
            (item) => item.isActive
        ).length;
    }

    get pendingDistributors() {

        return this.distributors.filter(
            (item) => item.Login_Status__c === 'Pending'
        ).length;
    }

    get filteredCount() {
        return this.filteredDistributors.length;
    }

    /*
     * Search by distributor name, email or standard Account Phone.
     */
    get filteredDistributors() {

        const term = this.searchTerm
            .trim()
            .toLowerCase();

        if (!term) {
            return this.distributors;
        }

        return this.distributors.filter((item) => {

            return [
                item.Name,
                item.Email__c,
                item.Phone
            ].some((value) =>
                String(value || '')
                    .toLowerCase()
                    .includes(term)
            );
        });
    }

    get hasDistributors() {
        return this.filteredDistributors.length > 0;
    }

    get showEmptyState() {

        return !this.isLoading &&
            !this.errorMessage &&
            this.filteredDistributors.length === 0;
    }

    /*
     * Confirmation modal content.
     */
    get confirmationTitle() {

        return this.selectedActiveValue
            ? 'Activate Distributor?'
            : 'Deactivate Distributor?';
    }

    get confirmationMessage() {

        if (this.selectedActiveValue) {

            return `Are you sure you want to activate ${this.selectedDistributorName}? Login access will remain pending until activation is completed.`;
        }

        return `Are you sure you want to deactivate ${this.selectedDistributorName}?`;
    }

    /*
     * Search handler.
     */
    handleSearch(event) {
        this.searchTerm = event.target.value || '';
    }

    handleClearSearch() {
        this.searchTerm = '';
    }

    /*
     * Refresh the list.
     */
    async handleRefresh() {

        if (!this.wiredDistributorsResult) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        try {

            await refreshApex(
                this.wiredDistributorsResult
            );

        } catch (error) {

            this.errorMessage =
                this.getErrorMessage(error);

            this.showToast(
                'Refresh Failed',
                this.errorMessage,
                'error'
            );

        } finally {
            this.isLoading = false;
        }
    }

    /*
     * Open confirmation modal.
     */
    handleToggleStatus(event) {

        this.selectedDistributorId =
            event.currentTarget.dataset.id;

        this.selectedActiveValue =
            event.currentTarget.dataset.active !== 'true';

        const distributor = this.distributors.find(
            (item) =>
                item.Id === this.selectedDistributorId
        );

        this.selectedDistributorName = distributor
            ? distributor.Name
            : 'this distributor';

        this.showConfirmation = true;
    }

    /*
     * Cancel confirmation.
     */
    handleCancelConfirmation() {

        this.showConfirmation = false;
        this.selectedDistributorId = undefined;
        this.selectedDistributorName = undefined;
        this.selectedActiveValue = undefined;
    }

    /*
     * Confirm activation/deactivation.
     */
    async handleConfirmStatusChange() {

        if (
            !this.selectedDistributorId ||
            this.isLoading
        ) {
            return;
        }

        const accountId = this.selectedDistributorId;
        const activate = this.selectedActiveValue;

        this.isLoading = true;

        try {

            await updateDistributorStatus({
                accountId,
                shouldActivate: activate
            });

            this.showToast(
                'Success',
                activate
                    ? 'Distributor activated successfully. Login activation is still required.'
                    : 'Distributor deactivated successfully.',
                'success'
            );

            this.showConfirmation = false;

            await refreshApex(
                this.wiredDistributorsResult
            );

        } catch (error) {

            this.showToast(
                'Update Failed',
                this.getErrorMessage(error),
                'error'
            );

        } finally {

            this.isLoading = false;

            this.selectedDistributorId = undefined;
            this.selectedDistributorName = undefined;
            this.selectedActiveValue = undefined;
        }
    }

    /*
     * Send activation email.
     */
    async handleSendCredentials(event) {

        const accountId =
            event.currentTarget.dataset.id;

        if (!accountId || this.isLoading) {
            return;
        }

        this.isLoading = true;

        try {

            const message =
                await sendDistributorCredentials({
                    accountId
                });

            this.showToast(
                'Activation Email Sent',
                message || 'Activation email sent successfully.',
                'success'
            );

            await refreshApex(
                this.wiredDistributorsResult
            );

        } catch (error) {

            this.showToast(
                'Email Failed',
                this.getErrorMessage(error),
                'error'
            );

        } finally {
            this.isLoading = false;
        }
    }

    /*
     * Extract readable Salesforce errors.
     */
    getErrorMessage(error) {

        if (error?.body?.message) {
            return error.body.message;
        }

        if (
            error?.body?.pageErrors &&
            error.body.pageErrors.length > 0
        ) {
            return error.body.pageErrors
                .map((item) => item.message)
                .join(', ');
        }

        return error?.message ||
            'An unexpected error occurred. Please try again.';
    }

    /*
     * Show Salesforce toast.
     */
    showToast(title, message, variant) {

        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}