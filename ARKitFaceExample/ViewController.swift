/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import ARKit
import SceneKit
import UIKit

class ViewController: UIViewController, ARSessionDelegate {
    // MARK: Render
    var renderer: SCNRenderer!
    var scene2: SCNScene!
    var presentScnView: SCNView!
    var plane: SCNGeometry!
    var device:MTLDevice!
    var commandQueue: MTLCommandQueue!
    var offscreenTexture:MTLTexture!
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = Int(4)
    let bitsPerComponent = Int(8)
    let bitsPerPixel:Int = 32
    var textureSizeX:Int = 360 * 3
    var textureSizeY:Int = 640 * 3
    
    // MARK: Outlets

    @IBOutlet var sceneView: ARSCNView!

    @IBOutlet weak var blurView: UIVisualEffectView!

    lazy var statusViewController: StatusViewController = {
        return childViewControllers.lazy.flatMap({ $0 as? StatusViewController }).first!
    }()

    // MARK: Properties

    /// Convenience accessor for the session owned by ARSCNView.
    var session: ARSession {
        return sceneView.session
    }

    var nodeForContentType = [VirtualContentType: VirtualFaceNode]()
    
    let contentUpdater = VirtualContentUpdater()
    
    var selectedVirtualContent: VirtualContentType = .overlayModel {
        didSet {
            // Set the selected content based on the content type.
            contentUpdater.virtualFaceNode = nodeForContentType[selectedVirtualContent]
        }
    }

    // MARK: - View Controller Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.delegate = contentUpdater
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        
        createFaceGeometry()

        // Set the initial face content, if any.
        contentUpdater.virtualFaceNode = nodeForContentType[selectedVirtualContent]

        // Hook up status view controller callback(s).
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartExperience()
        }
        
        setupRenderConfiguration()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        /*
            AR experiences typically involve moving the device without
            touch input for some time, so prevent auto screen dimming.
        */
        UIApplication.shared.isIdleTimerDisabled = true
        
        resetTracking()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        session.pause()
    }
    
    // MARK: - Setup
    
    func setupRenderConfiguration() {
        scene2 = SCNScene()
        presentScnView = SCNView(frame: .zero)
        plane = SCNPlane(width: 10, height: 10)
        let planeNode = SCNNode(geometry: plane)
//        scene2.rootNode.addChildNode(planeNode)
        
        presentScnView.scene = scene2
        setupMetal()
        setupTexture()
        self.view.addSubview(presentScnView)
        presentScnView.frame = CGRect(x: 30, y: 30, width: 360, height: 640)
//        plane.materials.first?.diffuse.contents = offscreenTexture
        let box = SCNBox(width: 3.6, height: 6.4, length: 5, chamferRadius: 0.5)
        scene2.rootNode.addChildNode(SCNNode(geometry: box))
        box.materials.first?.diffuse.contents = offscreenTexture
        
        presentScnView.isPlaying = true
        presentScnView.allowsCameraControl = true
        sceneView.isPlaying = true
        
    }
    
    func doRender() {
        //rendering to a MTLTexture, so the viewport is the size of this texture
        let viewport = CGRect(x: 0, y: 0, width: CGFloat(textureSizeX), height: CGFloat(textureSizeY))
        
        //write to offscreenTexture, clear the texture before rendering using green, store the result
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = offscreenTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0); //green
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let commandBuffer = commandQueue.makeCommandBuffer()!
        // reuse scene1 and the current point of view
        renderer.scene = sceneView.scene
        renderer.pointOfView = sceneView.pointOfView
        renderer.render(atTime: 0, viewport: viewport, commandBuffer: commandBuffer, passDescriptor: renderPassDescriptor)

        commandBuffer.commit()
        
        var outPixelbuffer: CVPixelBuffer?
        if let datas = offscreenTexture.buffer?.contents() {
            CVPixelBufferCreateWithBytes(kCFAllocatorDefault, offscreenTexture.width,
                                         offscreenTexture.height, kCVPixelFormatType_64RGBAHalf, datas,
                                         offscreenTexture.bufferBytesPerRow, nil, nil, nil, &outPixelbuffer);
        }

    }
    
    func setupMetal() {
        if let defaultMtlDevice = MTLCreateSystemDefaultDevice() {
            device = defaultMtlDevice
            commandQueue = device.makeCommandQueue()
            renderer = SCNRenderer(device: device, options: nil)
        } else {
            fatalError("iOS simulator does not support Metal, this example can only be run on a real device.")
        }
    }
    
    func setupTexture() {
        
        var rawData0 = [UInt8](repeating: 0, count: Int(textureSizeX) * Int(textureSizeY) * 4)
        
        let bytesPerRow = 4 * Int(textureSizeX)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        
        let context = CGContext(data: &rawData0, width: Int(textureSizeX), height: Int(textureSizeY), bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: rgbColorSpace, bitmapInfo: bitmapInfo)!
        context.setFillColor(UIColor.green.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(textureSizeX), height: CGFloat(textureSizeY)))

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.rgba8Unorm, width: Int(textureSizeX), height: Int(textureSizeY), mipmapped: false)
        
        textureDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.renderTarget.rawValue | MTLTextureUsage.shaderRead.rawValue)
        
        let textureA = device.makeTexture(descriptor: textureDescriptor)!
        
        let region = MTLRegionMake2D(0, 0, Int(textureSizeX), Int(textureSizeY))
        textureA.replace(region: region, mipmapLevel: 0, withBytes: &rawData0, bytesPerRow: Int(bytesPerRow))

        offscreenTexture = textureA
    }
    
    func makeBGRACoreVideoTexture(size: CGSize, pixelBuffer: CVPixelBuffer) {
        
    }

//    - (id<MTLTexture>) makeBGRACoreVideoTexture:(CGSize)size
//                            cvPixelBufferRefPtr:(CVPixelBufferRef*)cvPixelBufferRefPtr
//    {
//      int width = (int) size.width;
//      int height = (int) size.height;
//
//      // CoreVideo pixel buffer backing the indexes texture
//
//      NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
//                               [NSNumber numberWithBool:YES], kCVPixelBufferMetalCompatibilityKey,
//                               [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey,
//                               [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey,
//                               nil];
//
//      CVPixelBufferRef pxbuffer = NULL;
//
//      CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
//                                            width,
//                                            height,
//                                            kCVPixelFormatType_32BGRA,
//                                            (__bridge CFDictionaryRef) options,
//                                            &pxbuffer);
//
//      NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL);
//
//      *cvPixelBufferRefPtr = pxbuffer;
//
//      CVMetalTextureRef cvTexture = NULL;
//
//      CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
//                                                               _textureCache,
//                                                               pxbuffer,
//                                                               nil,
//                                                               MTLPixelFormatBGRA8Unorm,
//                                                               CVPixelBufferGetWidth(pxbuffer),
//                                                               CVPixelBufferGetHeight(pxbuffer),
//                                                               0,
//                                                               &cvTexture);
//
//      NSParameterAssert(ret == kCVReturnSuccess && cvTexture != NULL);
//
//      id<MTLTexture> metalTexture = CVMetalTextureGetTexture(cvTexture);
//
//      CFRelease(cvTexture);
//
//      return metalTexture;
//    }

    /// - Tag: CreateARSCNFaceGeometry
    func createFaceGeometry() {
        // This relies on the earlier check of `ARFaceTrackingConfiguration.isSupported`.
        let device = sceneView.device!
        let maskGeometry = ARSCNFaceGeometry(device: device)!
        let glassesGeometry = ARSCNFaceGeometry(device: device)!
        
        nodeForContentType = [
            .faceGeometry: Mask(geometry: maskGeometry),
            .overlayModel: GlassesOverlay(geometry: glassesGeometry),
            .blendShapeModel: RobotHead()
        ]
    }
    
    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.flatMap({ $0 }).joined(separator: "\n")
        
        DispatchQueue.main.async {
            self.displayErrorMessage(title: "The AR session failed.", message: errorMessage)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        blurView.isHidden = false
        statusViewController.showMessage("""
        SESSION INTERRUPTED
        The session will be reset after the interruption has ended.
        """, autoHide: false)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        blurView.isHidden = true
        
        DispatchQueue.main.async {
            self.resetTracking()
        }
    }
    
    /// - Tag: ARFaceTrackingSetup
    func resetTracking() {
        statusViewController.showMessage("STARTING A NEW SESSION")
        
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        doRender()
    }
    
    // MARK: - Interface Actions

    /// - Tag: restartExperience
    func restartExperience() {
        // Disable Restart button for a while in order to give the session enough time to restart.
        statusViewController.isRestartExperienceButtonEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.statusViewController.isRestartExperienceButtonEnabled = true
        }

        resetTracking()
    }
    
    // MARK: - Error handling
    
    func displayErrorMessage(title: String, message: String) {
        // Blur the background.
        blurView.isHidden = false
        
        // Present an alert informing about the error that has occurred.
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
            alertController.dismiss(animated: true, completion: nil)
            self.blurView.isHidden = true
            self.resetTracking()
        }
        alertController.addAction(restartAction)
        present(alertController, animated: true, completion: nil)
    }
}

extension ViewController: UIPopoverPresentationControllerDelegate {

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        /*
         Popover segues should not adapt to fullscreen on iPhone, so that
         the AR session's view controller stays visible and active.
        */
        return .none
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        /*
         All segues in this app are popovers even on iPhone. Configure their popover
         origin accordingly.
        */
        guard let popoverController = segue.destination.popoverPresentationController, let button = sender as? UIButton else { return }
        popoverController.delegate = self
        popoverController.sourceRect = button.bounds

        // Set up the view controller embedded in the popover.
        let contentSelectionController = popoverController.presentedViewController as! ContentSelectionController

        // Set the initially selected virtual content.
        contentSelectionController.selectedVirtualContent = selectedVirtualContent

        // Update our view controller's selected virtual content when the selection changes.
        contentSelectionController.selectionHandler = { [unowned self] newSelectedVirtualContent in
            self.selectedVirtualContent = newSelectedVirtualContent
        }
    }
}
