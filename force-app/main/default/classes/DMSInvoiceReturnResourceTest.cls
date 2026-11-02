@IsTest
private class DMSInvoiceReturnResourceTest {
    private static final String SESSION_TOKEN =
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

    @IsTest
    static void invoiceDraftSnapshotsOrderAndPostingDoesNotDeductStock() {
        TestData data = createTestData(5);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-draft-once'
        });
        Test.startTest();
        DMSInvoiceReturnResource.postDocumentAction();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> draftResponse = parseResponse();
        Map<String, Object> draftDetails =
            (Map<String, Object>) draftResponse.get('invoice');
        Id invoiceId = (Id) draftDetails.get('id');
        DMS_Invoice__c draft = [
            SELECT Status__c, Subtotal__c, Total_Discount__c,
                   Taxable_Amount__c, Tax_Amount__c, Invoice_Total__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
        ];
        System.assertEquals('Draft', draft.Status__c);
        System.assertEquals(20, draft.Subtotal__c);
        System.assertEquals(4, draft.Total_Discount__c);
        System.assertEquals(16, draft.Taxable_Amount__c);
        System.assertEquals(1.6, draft.Tax_Amount__c);
        System.assertEquals(17.6, draft.Invoice_Total__c);
        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-draft-once'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Posted', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);
    }

    @IsTest
    static void invoicePostingDoesNotDeductStockBeforeDispatch() {
        TestData data = createTestData(1);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Posted', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);
        System.assertEquals(1, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);
    }

    @IsTest
    static void draftOrderCanGenerateAndPostInvoiceWithoutApproval() {
        TestData data = createTestData(5);
        update new Order(Id = data.orderId, Status = 'Draft');

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'preapproval-invoice'
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> responseInvoice =
            (Map<String, Object>) parseResponse().get('invoice');
        System.assertEquals(String.valueOf(data.orderId), responseInvoice.get('orderId'));
        System.assertEquals('Secondary', responseInvoice.get('salesType'));
        System.assertEquals('Draft', responseInvoice.get('status'));
        System.assertEquals(17.6, responseInvoice.get('total'));
        System.assertEquals(1, ((List<Object>) responseInvoice.get('lines')).size());

        Id invoiceId = (Id) responseInvoice.get('id');
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'preapproval-invoice-retry'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            String.valueOf(invoiceId),
            ((Map<String, Object>) parseResponse().get('invoice')).get('id')
        );
        System.assertEquals(1, [
            SELECT COUNT()
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c = :data.orderId
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Posted', [
            SELECT Status__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
        ].Status__c);
    }

    @IsTest
    static void recordsPaymentsListsReceiptsAndSupportsIdempotentRetries() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        Map<String, Object> firstPayment = new Map<String, Object>{
            'action' => 'recordPayment',
            'invoiceId' => invoiceId,
            'amount' => 5,
            'paymentMethod' => 'UPI',
            'referenceNumber' => 'UPI-1001',
            'requestKey' => 'payment-receipt-once'
        };
        setRequest('POST', firstPayment);
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> firstResponse = parseResponse();
        Map<String, Object> firstReceipt =
            (Map<String, Object>) firstResponse.get('receipt');
        System.assertEquals(5, firstReceipt.get('amount'));
        System.assertEquals(5, firstReceipt.get('amountPaid'));
        System.assertEquals(12.6, firstReceipt.get('balanceDue'));

        setRequest('POST', firstPayment);
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            firstReceipt.get('id'),
            ((Map<String, Object>) parseResponse().get('receipt')).get('id')
        );
        System.assertEquals(1, [
            SELECT COUNT()
            FROM DMS_Payment_Receipt__c
            WHERE Invoice__c = :invoiceId
        ]);

        firstPayment.put('amount', 6);
        setRequest('POST', firstPayment);
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(5, [
            SELECT Amount_Paid__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
        ].Amount_Paid__c);

        setRequest('GET', new Map<String, Object>());
        DMSInvoiceReturnResource.getDocuments();
        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> invoiceSummary =
            (Map<String, Object>) ((List<Object>) parseResponse().get('invoices'))[0];
        System.assertEquals('Partially Paid', invoiceSummary.get('paymentStatus'));
        System.assertEquals(
            1,
            ((List<Object>) invoiceSummary.get('paymentReceipts')).size()
        );
        Map<String, Object> listedReceipt =
            (Map<String, Object>) ((List<Object>) invoiceSummary.get('paymentReceipts'))[0];
        System.assertEquals(firstReceipt.get('id'), listedReceipt.get('id'));
        System.assertEquals('UPI', listedReceipt.get('paymentMethod'));

        setRequest('POST', new Map<String, Object>{
            'action' => 'recordPayment',
            'invoiceId' => invoiceId,
            'amount' => 12.6,
            'paymentMethod' => 'Bank Transfer',
            'requestKey' => 'payment-receipt-final'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> finalReceipt =
            (Map<String, Object>) parseResponse().get('receipt');
        System.assertEquals(17.6, finalReceipt.get('amountPaid'));
        System.assertEquals(0, finalReceipt.get('balanceDue'));

        setRequest('GET', new Map<String, Object>());
        DMSInvoiceReturnResource.getDocuments();
        invoiceSummary =
            (Map<String, Object>) ((List<Object>) parseResponse().get('invoices'))[0];
        System.assertEquals('Paid', invoiceSummary.get('paymentStatus'));
        System.assertEquals(
            2,
            ((List<Object>) invoiceSummary.get('paymentReceipts')).size()
        );
    }

    @IsTest
    static void rejectsPaymentsForDraftInvoicesAndAmountsAboveBalance() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'recordPayment',
            'invoiceId' => invoiceId,
            'amount' => 1,
            'paymentMethod' => 'Cash',
            'requestKey' => 'payment-before-posting'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'recordPayment',
            'invoiceId' => invoiceId,
            'amount' => 17.61,
            'paymentMethod' => 'Cash',
            'requestKey' => 'payment-over-balance'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM DMS_Payment_Receipt__c
            WHERE Invoice__c = :invoiceId
        ]);
        DMS_Invoice__c invoice = [
            SELECT Amount_Paid__c, Balance_Due__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
        ];
        System.assertEquals(0, invoice.Amount_Paid__c);
        System.assertEquals(17.6, invoice.Balance_Due__c);
    }

    @IsTest
    static void downloadsAndEmailsReceiptPdfOnlyForAuthorizedDistributor() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'recordPayment',
            'invoiceId' => invoiceId,
            'amount' => 5,
            'paymentMethod' => 'UPI',
            'referenceNumber' => 'UPI-RECEIPT-PDF',
            'requestKey' => 'receipt-pdf-payment'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        Id receiptId = (Id) ((Map<String, Object>) parseResponse().get('receipt')).get('id');

        Test.setCurrentPage(Page.DMSPaymentReceiptPdf);
        ApexPages.currentPage().getParameters().put('id', String.valueOf(receiptId));
        Long expiresAt = System.now().addMinutes(1).getTime();
        String sessionTokenHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(SESSION_TOKEN))
        );
        String signedValue = String.valueOf(receiptId) + '|' +
            String.valueOf(data.distributorId) + '|' + String.valueOf(expiresAt);
        ApexPages.currentPage().getParameters().put(
            'distributorId',
            String.valueOf(data.distributorId)
        );
        ApexPages.currentPage().getParameters().put('expiresAt', String.valueOf(expiresAt));
        ApexPages.currentPage().getParameters().put(
            'signature',
            EncodingUtil.convertToHex(Crypto.generateMac(
                'HmacSHA256',
                Blob.valueOf(signedValue),
                Blob.valueOf(sessionTokenHash)
            ))
        );
        DMSPaymentReceiptPdfController pdfController =
            new DMSPaymentReceiptPdfController();
        System.assert(pdfController.receipt.Name.startsWith('DMSRCP-'));
        System.assertEquals(invoiceId, pdfController.invoice.Id);
        System.assertEquals(1, pdfController.invoiceLines.size());

        setRequest('POST', new Map<String, Object>{
            'action' => 'downloadReceipt',
            'receiptId' => receiptId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().startsWith('%PDF-1.4'));

        setRequest('POST', new Map<String, Object>{
            'action' => 'emailReceipt',
            'receiptId' => receiptId,
            'recipientEmail' => 'customer@example.invalid'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            'customer@example.invalid',
            parseResponse().get('recipientEmail')
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'emailReceipt',
            'receiptId' => data.orderId,
            'recipientEmail' => 'customer@example.invalid'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(404, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'emailReceipt',
            'receiptId' => receiptId,
            'recipientEmail' => 'not-an-email'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        Test.setCurrentPage(Page.DMSPaymentReceiptPdf);
        ApexPages.currentPage().getParameters().put('id', 'invalid-id');
        DMSPaymentReceiptPdfController invalidController =
            new DMSPaymentReceiptPdfController();
        System.assertEquals(null, invalidController.receipt);
    }

    @IsTest
    static void primaryInvoiceCreationIsCompanyOwned() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        update new Order(
            Id = data.orderId,
            Type = 'Primary Order',
            Outlet__c = null
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'primary-order-invoice'
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(403, RestContext.response.statusCode);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM DMS_Invoice__c WHERE Secondary_Order__c = :data.orderId]
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(403, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'cancelInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(403, RestContext.response.statusCode);
        System.assertEquals('Draft', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);
    }

    @IsTest
    static void postingInvoicePreservesItsReservationUntilDispatch() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        String reservationReference = 'DMS-RES-' + String.valueOf(data.orderId) + '-invoice-test';
        update new Inventory__c(
            Id = data.inventoryId,
            Available_Quantity__c = 3,
            Reserved_Quantity__c = 2
        );
        insert new Inventory_Transaction__c(
            Inventory__c = data.inventoryId,
            Transaction_Type__c = 'Stock Reservation',
            Quantity__c = 2,
            Transaction_Date__c = System.now(),
            Reference_Number__c = reservationReference,
            Transaction_Description__c = 'Approved order reservation'
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();

        Inventory__c inventory = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(3, inventory.Available_Quantity__c);
        System.assertEquals(2, inventory.Reserved_Quantity__c);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
              AND Transaction_Type__c = 'Secondary Order Sale'
        ]);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Invoice__c = :invoiceId
              AND Transaction_Type__c = 'Stock Release'
        ]);
    }

    @IsTest
    static void secondaryDispatchConfirmationDeductsStockOnceAndDeliveryDoesNotDeductAgain() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);

        OrderItem orderLine = [
            SELECT Id FROM OrderItem WHERE OrderId = :data.orderId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createDispatch',
            'invoiceId' => invoiceId,
            'requestKey' => 'dispatch-once',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'orderItemId' => orderLine.Id,
                    'quantity' => 2
                }
            }
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        Id dispatchId = (Id) ((Map<String, Object>) parseResponse().get('dispatch')).get('id');
        setRequest('POST', new Map<String, Object>{
            'action' => 'createDispatch',
            'invoiceId' => invoiceId,
            'requestKey' => 'dispatch-once',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'orderItemId' => orderLine.Id,
                    'quantity' => 2
                }
            }
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            dispatchId,
            (Id) ((Map<String, Object>) parseResponse().get('dispatch')).get('id')
        );
        System.assertEquals(1, [
            SELECT COUNT()
            FROM DMS_Dispatch__c
            WHERE Invoice__c = :invoiceId
        ]);
        setRequest('GET', new Map<String, Object>());
        DMSFulfillmentResource.getFulfillment();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, ((List<Object>) parseResponse().get('dispatches')).size());
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);

        setRequest('POST', new Map<String, Object>{
            'action' => 'confirmDispatch',
            'dispatchId' => dispatchId
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(3, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Dispatch__c = :dispatchId
              AND Transaction_Type__c = 'Secondary Order Sale'
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'confirmDispatch',
            'dispatchId' => dispatchId
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(3, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);

        DMS_Dispatch_Line__c dispatchLine = [
            SELECT Id FROM DMS_Dispatch_Line__c
            WHERE Dispatch__c = :dispatchId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'recordDelivery',
            'dispatchId' => dispatchId,
            'recipientName' => 'Outlet receiving contact',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'dispatchLineId' => dispatchLine.Id,
                    'deliveredQuantity' => 1,
                    'damagedQuantity' => 0
                }
            }
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Partially Delivered', [
            SELECT Status__c FROM DMS_Dispatch__c WHERE Id = :dispatchId
        ].Status__c);
        System.assertEquals(3, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);

        setRequest('POST', new Map<String, Object>{
            'action' => 'recordDelivery',
            'dispatchId' => dispatchId,
            'recipientName' => 'Outlet receiving contact',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'dispatchLineId' => dispatchLine.Id,
                    'deliveredQuantity' => 2,
                    'damagedQuantity' => 0
                }
            }
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Delivered', [
            SELECT Status__c FROM DMS_Dispatch__c WHERE Id = :dispatchId
        ].Status__c);
        setRequest('GET', new Map<String, Object>());
        DMSFulfillmentResource.getFulfillment();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, ((List<Object>) parseResponse().get('dispatches')).size());
        System.assertEquals(3, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
    }

    @IsTest
    static void confirmedReservedDispatchConsumesReservationWithoutTouchingAvailableStock() {
        TestData data = createTestData(5);
        update new Order(
            Id = data.orderId,
            DMS_Fulfillment_Warehouse__c = data.warehouseId,
            DMS_Allocation_Status__c = 'Reserved'
        );
        update new Inventory__c(
            Id = data.inventoryId,
            Available_Quantity__c = 3,
            Reserved_Quantity__c = 2
        );
        String reservationReference =
            'DMS-RES-' + String.valueOf(data.orderId) + '-dispatch-test';
        insert new Inventory_Transaction__c(
            Inventory__c = data.inventoryId,
            Transaction_Type__c = 'Stock Reservation',
            Quantity__c = 2,
            Transaction_Date__c = System.now(),
            Reference_Number__c = reservationReference,
            Transaction_Description__c = 'Approved order reservation'
        );
        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        OrderItem orderLine = [
            SELECT Id FROM OrderItem WHERE OrderId = :data.orderId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createDispatch',
            'invoiceId' => invoiceId,
            'requestKey' => 'dispatch-reserved-once',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'orderItemId' => orderLine.Id,
                    'quantity' => 2
                }
            }
        });
        DMSFulfillmentResource.postFulfillmentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        Id dispatchId = (Id) ((Map<String, Object>) parseResponse().get('dispatch')).get('id');
        setRequest('POST', new Map<String, Object>{
            'action' => 'confirmDispatch',
            'dispatchId' => dispatchId
        });
        DMSFulfillmentResource.postFulfillmentAction();

        Inventory__c inventory = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ];
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(3, inventory.Available_Quantity__c);
        System.assertEquals(0, inventory.Reserved_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE DMS_Dispatch__c = :dispatchId
              AND Transaction_Type__c = 'Secondary Order Sale'
        ]);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = :reservationReference
              AND Transaction_Type__c = 'Stock Release'
        ]);
    }

    @IsTest
    static void invoiceDraftRequiresAndPreservesAnActiveReservationWhenMarkedReserved() {
        TestData data = createTestData(5);
        update new Order(
            Id = data.orderId,
            DMS_Fulfillment_Warehouse__c = data.warehouseId,
            DMS_Allocation_Status__c = 'Reserved'
        );
        update new Inventory__c(
            Id = data.inventoryId,
            Available_Quantity__c = 3,
            Reserved_Quantity__c = 2
        );
        String reservationReference = 'DMS-RES-' + String.valueOf(data.orderId) + '-draft-test';
        insert new Inventory_Transaction__c(
            Inventory__c = data.inventoryId,
            Transaction_Type__c = 'Stock Reservation',
            Quantity__c = 2,
            Transaction_Date__c = System.now(),
            Reference_Number__c = reservationReference,
            Transaction_Description__c = 'Approved order reservation'
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-reservation-draft'
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(201, RestContext.response.statusCode);
        Inventory__c inventory = [
            SELECT Available_Quantity__c, Reserved_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ];
        System.assertEquals(3, inventory.Available_Quantity__c);
        System.assertEquals(2, inventory.Reserved_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = :reservationReference
              AND Transaction_Type__c = 'Stock Reservation'
        ]);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Reference_Number__c = :reservationReference
              AND Transaction_Type__c = 'Stock Release'
        ]);
    }

    @IsTest
    static void invoiceDraftRejectsReservedOrderWithoutActiveReservation() {
        TestData data = createTestData(5);
        update new Order(
            Id = data.orderId,
            DMS_Fulfillment_Warehouse__c = data.warehouseId,
            DMS_Allocation_Status__c = 'Reserved'
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-missing-reservation'
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c = :data.orderId
        ]);
        System.assertEquals(5, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
    }

    @IsTest
    static void invoiceDraftCalculatesEachProductUsingItsConfiguredTaxRate() {
        TestData data = createTestData(5, true);
        Id invoiceId = createDraft(data);
        DMS_Invoice__c invoice = [
            SELECT Subtotal__c, Total_Discount__c, Taxable_Amount__c,
                   Tax_Amount__c, Invoice_Total__c
            FROM DMS_Invoice__c
            WHERE Id = :invoiceId
        ];
        System.assertEquals(40, invoice.Subtotal__c);
        System.assertEquals(4, invoice.Total_Discount__c);
        System.assertEquals(36, invoice.Taxable_Amount__c);
        System.assertEquals(2.6, invoice.Tax_Amount__c);
        System.assertEquals(38.6, invoice.Invoice_Total__c);
        System.assertEquals(2, [
            SELECT COUNT() FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId
        ]);
        System.assertEquals(5, [
            SELECT Available_Quantity__c FROM Inventory__c WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
    }

    @IsTest
    static void rejectsInvalidSessionAndOverLimitFinancialDocuments() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        RestContext.request.headers.put('X-DMS-Session', 'invalid');
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(401, RestContext.response.statusCode);
        System.assertEquals('Draft', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 18,
            'requestKey' => 'credit-too-large'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT() FROM DMS_Credit_Note__c WHERE Invoice__c = :invoiceId
        ]);

        DMS_Invoice_Line__c line = [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-too-large',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => line.Id,
                    'quantity' => 3
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Return_Request__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);
    }

    @IsTest
    static void createsCreditAndReturnDraftsAndListsTheirRealDetails() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        markInvoiceLegacyDeducted(data, invoiceId);

        DMS_Invoice_Line__c line = [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 1,
            'requestKey' => 'credit-draft-test'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-draft-test',
            'remarks' => 'Test return',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => line.Id,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);

        OrderItem orderLine = [
            SELECT Product2Id
            FROM OrderItem
            WHERE OrderId = :data.orderId
            LIMIT 1
        ];
        Scheme__c scheme = new Scheme__c(
            Scheme_Name__c = 'Invoice list scheme',
            Scheme_Type__c = 'Free Product',
            Sales_Type__c = 'Secondary',
            Active__c = true,
            Status__c = 'Active'
        );
        insert scheme;
        Scheme_Product__c schemeProduct = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product__c = orderLine.Product2Id,
            Minimum_Quantity__c = 1,
            Free_Quantity__c = 1,
            Active__c = true
        );
        insert schemeProduct;
        insert new Order_Scheme__c(
            Order__c = data.orderId,
            Scheme__c = scheme.Id,
            Scheme_Product__c = schemeProduct.Id,
            Applied_Quantity__c = 2,
            Free_Quantity__c = 1,
            Discount_Amount__c = 0,
            Status__c = 'Applied'
        );

        setRequest('GET', new Map<String, Object>());
        DMSInvoiceReturnResource.getDocuments();
        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> payload = parseResponse();
        List<Object> invoices = (List<Object>) payload.get('invoices');
        List<Object> creditNotes = (List<Object>) payload.get('creditNotes');
        List<Object> returns = (List<Object>) payload.get('returns');
        List<Object> orders = (List<Object>) payload.get('orders');
        System.assertEquals(1, invoices.size());
        System.assertEquals(1, creditNotes.size());
        System.assertEquals(1, returns.size());
        System.assertEquals(1, orders.size());
        Map<String, Object> orderLineSummary = (Map<String, Object>) (
            (List<Object>) ((Map<String, Object>) orders[0]).get('lines')
        )[0];
        System.assertEquals('Invoice list scheme', orderLineSummary.get('schemeName'));
        System.assertEquals(
            1,
            ((List<Object>) ((Map<String, Object>) invoices[0]).get('lines')).size()
        );
        System.assertEquals(
            1,
            ((List<Object>) ((Map<String, Object>) returns[0]).get('lines')).size()
        );
    }

    @IsTest
    static void preventsReturnRequestsBeforeAnyQuantityHasBeenDelivered() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        DMS_Invoice_Line__c invoiceLine = [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId LIMIT 1
        ];

        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-before-delivery',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invoiceLine.Id,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();

        System.assertEquals(409, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Return_Request__c
            WHERE DMS_Invoice__c = :invoiceId
        ]);
        System.assertEquals(5, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
    }

    @IsTest
    static void approvedCreditAndInspectedReturnPostFinancialAndStockMovementsOnce() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        markInvoiceLegacyDeducted(data, invoiceId);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 2,
            'requestKey' => 'credit-post-once'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        Id creditNoteId = (Id) ((Map<String, Object>) parseResponse().get('creditNote')).get('id');
        update new DMS_Credit_Note__c(Id = creditNoteId, Status__c = 'Approved');

        setRequest('POST', new Map<String, Object>{
            'action' => 'postCreditNote',
            'creditNoteId' => creditNoteId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Partially Credited', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);
        System.assertEquals(15.6, [
            SELECT Balance_Due__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Balance_Due__c);

        DMS_Invoice_Line__c invoiceLine = [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-complete-once',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invoiceLine.Id,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        Id returnId = (Id) ((Map<String, Object>) parseResponse().get('returnRequest')).get('id');
        update new Return_Request__c(Id = returnId, Status__c = 'Approved');
        Return_Item__c returnLine = [
            SELECT Id FROM Return_Item__c WHERE Return_Request__c = :returnId LIMIT 1
        ];

        setRequest('POST', new Map<String, Object>{
            'action' => 'inspectReturn',
            'returnId' => returnId,
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'returnItemId' => returnLine.Id,
                    'acceptedQuantity' => 1,
                    'rejectedQuantity' => 0,
                    'condition' => 'Good',
                    'restockDecision' => 'Restock'
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'completeReturn',
            'returnId' => returnId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(4, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Return_Request__c = :returnId AND Transaction_Type__c = 'Sales Return'
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'completeReturn',
            'returnId' => returnId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Inventory_Transaction__c
            WHERE Return_Request__c = :returnId AND Transaction_Type__c = 'Sales Return'
        ]);
    }

    @IsTest
    static void cancelsDraftAndRejectsUnconfiguredOrInvalidActions() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'cancelInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Cancelled', [
            SELECT Status__c FROM DMS_Invoice__c WHERE Id = :invoiceId
        ].Status__c);

        setRequest('POST', new Map<String, Object>{ 'action' => 'notSupported' });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>());
        RestContext.request.requestBody = Blob.valueOf('{');
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void validatesDuplicateOrdersMissingRecordsAndDocumentStates() {
        TestData data = createTestData(5);
        Id invoiceId = createDraft(data);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-different-key'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(
            String.valueOf(invoiceId),
            ((Map<String, Object>) parseResponse().get('invoice')).get('id')
        );
        System.assertEquals(1, [
            SELECT COUNT()
            FROM DMS_Invoice__c
            WHERE Secondary_Order__c = :data.orderId
        ]);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => data.orderId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(404, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Invalid Reason',
            'amount' => 1,
            'requestKey' => 'credit-invalid-reason'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Invalid Reason',
            'requestKey' => 'return-invalid-reason',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invoiceId,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'cancelInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        setRequest('POST', new Map<String, Object>{
            'action' => 'cancelInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);
    }

    @IsTest
    static void rejectsInvalidDocumentTransitionsAndReturnInspections() {
        TestData data = createTestData(5);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.outletId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-order-unavailable'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(404, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.outletId,
            'requestKey' => 'invoice-warehouse-unavailable'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        Id invoiceId = createDraft(data);
        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 1,
            'requestKey' => 'credit-on-draft-invoice'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postCreditNote',
            'creditNoteId' => data.orderId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(404, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'cancelInvoice',
            'invoiceId' => data.orderId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(404, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'postInvoice',
            'invoiceId' => invoiceId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        markInvoiceLegacyDeducted(data, invoiceId);
        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 1,
            'requestKey' => 'credit-awaiting-approval'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        Id creditNoteId = (Id) ((Map<String, Object>) parseResponse().get('creditNote')).get('id');
        update new DMS_Credit_Note__c(Id = creditNoteId, Approver__c = null);
        setRequest('POST', new Map<String, Object>{
            'action' => 'submitCreditNote',
            'creditNoteId' => creditNoteId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('Submitted', parseResponse().get('status'));
        User configuredApprover = [
            SELECT Id FROM User
            WHERE Name = :Label.DMS_Approval_User_Name AND IsActive = true
            LIMIT 1
        ];
        System.assertEquals(configuredApprover.Id, [
            SELECT Approver__c FROM DMS_Credit_Note__c WHERE Id = :creditNoteId
        ].Approver__c);
        setRequest('POST', new Map<String, Object>{
            'action' => 'createCreditNote',
            'invoiceId' => invoiceId,
            'reason' => 'Incorrect Pricing',
            'amount' => 1,
            'requestKey' => 'credit-awaiting-approval'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        setRequest('POST', new Map<String, Object>{
            'action' => 'postCreditNote',
            'creditNoteId' => creditNoteId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);

        DMS_Invoice_Line__c invoiceLine = [
            SELECT Id FROM DMS_Invoice_Line__c WHERE Invoice__c = :invoiceId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-inspection-validation',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invoiceLine.Id,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        Id returnId = (Id) ((Map<String, Object>) parseResponse().get('returnRequest')).get('id');
        setRequest('POST', new Map<String, Object>{
            'action' => 'createReturn',
            'invoiceId' => invoiceId,
            'reason' => 'Wrong Product',
            'requestKey' => 'return-inspection-validation',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invoiceLine.Id,
                    'quantity' => 1
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        update new Return_Request__c(
            Id = returnId,
            Status__c = 'Approved',
            Approver__c = null
        );

        setRequest('POST', new Map<String, Object>{
            'action' => 'submitReturn',
            'returnId' => returnId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(409, RestContext.response.statusCode);

        Return_Item__c returnItem = [
            SELECT Id FROM Return_Item__c WHERE Return_Request__c = :returnId LIMIT 1
        ];
        setRequest('POST', new Map<String, Object>{
            'action' => 'inspectReturn',
            'returnId' => returnId,
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'returnItemId' => returnItem.Id,
                    'acceptedQuantity' => 2,
                    'rejectedQuantity' => 0,
                    'condition' => 'Good',
                    'restockDecision' => 'Restock'
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'inspectReturn',
            'returnId' => returnId,
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'returnItemId' => returnItem.Id,
                    'acceptedQuantity' => 1,
                    'rejectedQuantity' => 0,
                    'condition' => 'Damaged',
                    'restockDecision' => 'Restock'
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(400, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'inspectReturn',
            'returnId' => returnId,
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'returnItemId' => returnItem.Id,
                    'acceptedQuantity' => 1,
                    'rejectedQuantity' => 0,
                    'condition' => 'Good',
                    'restockDecision' => 'Do Not Restock'
                }
            }
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);

        setRequest('POST', new Map<String, Object>{
            'action' => 'completeReturn',
            'returnId' => returnId
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(3, [
            SELECT Available_Quantity__c
            FROM Inventory__c
            WHERE Id = :data.inventoryId
        ].Available_Quantity__c);
    }

    private static void markInvoiceLegacyDeducted(TestData data, Id invoiceId) {
        OrderItem orderLine = [
            SELECT Quantity
            FROM OrderItem
            WHERE OrderId = :data.orderId
            LIMIT 1
        ];
        update new DMS_Invoice__c(
            Id = invoiceId,
            Stock_Deduction_Status__c = 'Already Deducted (Legacy)'
        );
        update new Inventory__c(
            Id = data.inventoryId,
            Available_Quantity__c = 5 - orderLine.Quantity
        );
        insert new Inventory_Transaction__c(
            Inventory__c = data.inventoryId,
            DMS_Invoice__c = invoiceId,
            Transaction_Type__c = 'Secondary Order Sale',
            Quantity__c = orderLine.Quantity,
            Transaction_Date__c = System.now(),
            Reference_Number__c = 'LEGACY-SALE-' + String.valueOf(invoiceId),
            Transaction_Description__c = 'Legacy invoice stock deduction'
        );
    }

    private static Id createDraft(TestData data) {
        setRequest('POST', new Map<String, Object>{
            'action' => 'createInvoice',
            'orderId' => data.orderId,
            'warehouseId' => data.warehouseId,
            'requestKey' => 'invoice-test-draft'
        });
        DMSInvoiceReturnResource.postDocumentAction();
        System.assertEquals(201, RestContext.response.statusCode);
        return (Id) ((Map<String, Object>) parseResponse().get('invoice')).get('id');
    }

    private static TestData createTestData(Decimal availableQuantity) {
        return createTestData(availableQuantity, false);
    }

    private static TestData createTestData(
        Decimal availableQuantity,
        Boolean withSecondProduct
    ) {
        Account distributor = new Account(
            Name = 'Invoice Test Distributor',
            Email__c = 'invoice-distributor@example.invalid',
            Account_Category__c = 'Distributor',
            Active__c = 'Yes',
            Login_Status__c = 'Active',
            DMS_Session_Token_Hash__c = EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(SESSION_TOKEN))
            ),
            DMS_Session_Expires_At__c = System.now().addHours(1)
        );
        insert distributor;
        Account outlet = new Account(
            Name = 'Invoice Test Outlet',
            Account_Category__c = 'Outlet',
            Active__c = 'Yes',
            Email__c = 'invoice-outlet@example.invalid',
            Distributor__c = distributor.Id
        );
        insert outlet;
        Product2 product = new Product2(
            Name = 'Invoice Test Product',
            ProductCode = 'INV-API-TEST',
            Category__c = 'Beverages',
            IsActive = true,
            DMS_Tax_Rate__c = 10
        );
        insert product;
        Id standardPricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = standardPricebookId, IsActive = true);
        insert new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 10,
            IsActive = true
        );
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Invoice Test Warehouse',
            Distributor__c = distributor.Id,
            Warehouse_Type__c = 'Distributor Warehouse',
            Warehouse_Status__c = 'Active'
        );
        insert warehouse;
        Order salesOrder = new Order(
            AccountId = distributor.Id,
            Outlet__c = outlet.Id,
            Type = 'Secondary Order',
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = standardPricebookId
        );
        insert salesOrder;
        PricebookEntry pricebookEntry = [
            SELECT Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :standardPricebookId
              AND Product2Id = :product.Id
            LIMIT 1
        ];
        insert new OrderItem(
            OrderId = salesOrder.Id,
            PricebookEntryId = pricebookEntry.Id,
            Quantity = 2,
            UnitPrice = 8
        );
        if (withSecondProduct) {
            Product2 secondProduct = new Product2(
                Name = 'Invoice Second Product',
                ProductCode = 'INV-API-TEST-2',
                Category__c = 'Beverages',
                IsActive = true,
                DMS_Tax_Rate__c = 5
            );
            insert secondProduct;
            PricebookEntry secondEntry = new PricebookEntry(
                Pricebook2Id = standardPricebookId,
                Product2Id = secondProduct.Id,
                UnitPrice = 20,
                IsActive = true
            );
            insert secondEntry;
            insert new OrderItem(
                OrderId = salesOrder.Id,
                PricebookEntryId = secondEntry.Id,
                Quantity = 1,
                UnitPrice = 20
            );
        }
        salesOrder.Status = 'Activated';
        update salesOrder;
        Inventory__c inventory = new Inventory__c(
            Warehouse__c = warehouse.Id,
            Product__c = product.Id,
            Available_Quantity__c = availableQuantity,
            Reserved_Quantity__c = 0,
            Minimum_Stock_Level__c = 1
        );
        insert inventory;
        return new TestData(distributor.Id, outlet.Id, warehouse.Id, salesOrder.Id, inventory.Id);
    }

    private static void setRequest(String method, Map<String, Object> payload) {
        RestContext.request = new RestRequest();
        RestContext.request.httpMethod = method;
        RestContext.request.headers.put('X-DMS-Session', SESSION_TOKEN);
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(payload));
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> parseResponse() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
    }

    private class TestData {
        Id distributorId;
        Id outletId;
        Id warehouseId;
        Id orderId;
        Id inventoryId;

        TestData(Id distributor, Id outlet, Id warehouse, Id orderRecord, Id inventory) {
            distributorId = distributor;
            outletId = outlet;
            warehouseId = warehouse;
            orderId = orderRecord;
            inventoryId = inventory;
        }
    }
}
