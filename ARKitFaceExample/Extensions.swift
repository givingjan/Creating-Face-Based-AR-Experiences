//
//  Extensions.swift
//  ARKitFaceExample
//
//  Created by Jan on 2021/3/18.
//  Copyright © 2021 Apple. All rights reserved.
//

import VideoToolbox
import UIKit

extension UIImage {
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, nil, &cgImage)

        guard let image = cgImage else {
            return nil
        }

        self.init(cgImage: image)
    }


}
