import { api, LightningElement } from 'lwc'
import lookupBarcode from '@salesforce/apex/DMSBarcodeScannerController.lookupBarcode'
import getDispatchLines from '@salesforce/apex/DMSBarcodeScannerController.getDispatchLines'
import scanDispatchBarcode from '@salesforce/apex/DMSBarcodeScannerController.scanDispatchBarcode'

const SUPPORTED_FORMATS = [
    'ean_8',
    'ean_13',
    'upc_a',
    'upc_e',
    'code_128',
    'code_39',
    'itf',
]

export default class DmsBarcodeScanner extends LightningElement {
    @api mode = 'lookup'
    @api recordId

    barcode = ''
    lookupResult
    dispatchResult
    errorMessage = ''
    successMessage = ''
    cameraMessage = ''
    isLoading = false
    cameraActive = false
    cameraStream
    barcodeDetector
    animationFrame
    lookupPending = false

    get dispatchScanMode() {
        return this.mode === 'dispatch'
    }

    get scannerTitle() {
        return this.dispatchScanMode ? 'Primary Dispatch Barcode Verification' : 'Barcode Scanner'
    }

    get scannerDescription() {
        return this.dispatchScanMode
            ? 'Scan dispatched products to record verification progress. Scanning does not update inventory.'
            : 'Scan a product barcode or enter it manually. Looking up a barcode does not change inventory.'
    }

    get scanButtonLabel() {
        return this.dispatchScanMode ? 'Record scan' : 'Look up'
    }

    get lookupDisabled() {
        return this.isLoading || !this.barcode.trim()
    }

    get hasStock() {
        return Boolean(this.lookupResult?.stock?.length)
    }

    get cameraButtonLabel() {
        return this.cameraActive ? 'Stop camera' : 'Scan with camera'
    }

    connectedCallback() {
        if (this.dispatchScanMode && this.recordId) {
            this.loadDispatchLines()
        }
    }

    handleBarcodeChange(event) {
        this.barcode = event.target.value
        this.errorMessage = ''
    }

    handleKeyDown(event) {
        if (event.key === 'Enter') {
            event.preventDefault()
            this.performLookup()
        }
    }

    handleLookup() {
        this.performLookup()
    }

    async performLookup(value = this.barcode) {
        const normalizedBarcode = value.trim()
        if (!normalizedBarcode || this.lookupPending) {
            return
        }

        this.lookupPending = true
        this.barcode = normalizedBarcode
        this.isLoading = true
        this.errorMessage = ''
        this.successMessage = ''
        this.lookupResult = undefined

        try {
            if (this.dispatchScanMode) {
                const result = await scanDispatchBarcode({
                    dispatchId: this.recordId,
                    barcode: normalizedBarcode,
                })
                this.dispatchResult = {
                    ...this.dispatchResult,
                    lines: this.dispatchResult.lines.map((line) => (
                        line.id === result.lineId
                            ? {
                                ...line,
                                scannedQuantity: result.scannedQuantity,
                                remainingQuantity: result.remainingQuantity,
                            }
                            : line
                    )),
                }
                this.successMessage =
                    `Counted 1 ${result.unitOfMeasure || 'unit'} for ${result.productName}. ${result.remainingQuantity} remaining.`
            } else {
                this.lookupResult = await lookupBarcode({ barcode: normalizedBarcode })
            }
        } catch (error) {
            this.errorMessage = error?.body?.message
                || error?.message
                || 'The barcode lookup could not be completed.'
        } finally {
            this.isLoading = false
            this.lookupPending = false
        }
    }

    async loadDispatchLines() {
        this.isLoading = true
        this.errorMessage = ''
        try {
            this.dispatchResult = await getDispatchLines({ dispatchId: this.recordId })
        } catch (error) {
            this.errorMessage = error?.body?.message
                || error?.message
                || 'Dispatch products could not be loaded.'
        } finally {
            this.isLoading = false
        }
    }

    async handleCameraToggle() {
        if (this.cameraActive) {
            this.stopCamera()
            return
        }

        this.cameraMessage = ''
        if (!navigator.mediaDevices?.getUserMedia) {
            this.cameraMessage = 'This browser does not support camera access. Enter the barcode or use a USB scanner.'
            return
        }

        const Detector = window.BarcodeDetector
        if (!Detector) {
            this.cameraMessage = 'Camera barcode decoding is not supported in this browser. Enter the barcode or use a USB scanner.'
            return
        }

        try {
            const formats = await Detector.getSupportedFormats()
            const usableFormats = formats.filter((format) => SUPPORTED_FORMATS.includes(format))
            this.barcodeDetector = new Detector(
                usableFormats.length ? { formats: usableFormats } : undefined,
            )
            this.cameraStream = await navigator.mediaDevices.getUserMedia({
                video: { facingMode: { ideal: 'environment' } },
            })
            this.cameraActive = true
            await new Promise((resolve) => requestAnimationFrame(resolve))
            const video = this.template.querySelector('video')
            if (!video) {
                throw new Error('The camera preview could not be started.')
            }
            video.srcObject = this.cameraStream
            await video.play()
            this.detectNextFrame()
        } catch (error) {
            this.stopCamera()
            this.cameraMessage = error?.name === 'NotAllowedError'
                ? 'Camera permission was denied. Enter the barcode or use a USB scanner.'
                : 'The camera could not be started. Enter the barcode or use a USB scanner.'
        }
    }

    async detectNextFrame() {
        if (!this.cameraActive || this.lookupPending) {
            if (this.cameraActive) {
                this.animationFrame = requestAnimationFrame(() => this.detectNextFrame())
            }
            return
        }

        const video = this.template.querySelector('video')
        if (!video || video.readyState < 2) {
            this.animationFrame = requestAnimationFrame(() => this.detectNextFrame())
            return
        }

        try {
            const detections = await this.barcodeDetector.detect(video)
            const value = detections.find((detection) => detection.rawValue)?.rawValue
            if (value) {
                this.stopCamera()
                await this.performLookup(value)
                return
            }
        } catch {
            this.stopCamera()
            this.cameraMessage = 'Camera scanning failed. Enter the barcode or use a USB scanner.'
            return
        }

        if (this.cameraActive) {
            this.animationFrame = requestAnimationFrame(() => this.detectNextFrame())
        }
    }

    stopCamera() {
        if (this.animationFrame) {
            cancelAnimationFrame(this.animationFrame)
            this.animationFrame = undefined
        }
        this.cameraStream?.getTracks().forEach((track) => track.stop())
        this.cameraStream = undefined
        this.barcodeDetector = undefined
        this.cameraActive = false
    }

    disconnectedCallback() {
        this.stopCamera()
    }
}
