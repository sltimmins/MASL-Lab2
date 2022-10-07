//
//  AnalyzerModel.swift
//  AudioLabSwift
//
//  Created by Wyatt Saltzman on 10/5/22.
//  Copyright © 2022 Eric Larson. All rights reserved.
//

import Foundation
import Metal

class AnalyzerModel {
//    let AUDIO_BUFFER_SIZE = 1024 * 4
//    let audio = AudioModel(buffer_size: 1024 * 4)
//
//    lazy var maxFreqs:[Float] = {
//        return Array.init(repeating: 0.0, count: 2);
//    }()
//
//    lazy var maxFreqsi:[Int] = {
//        return Array.init(repeating: 0, count: 2);
//    }()
//
//    var graph:MetalGraph?
    
    private var AUDIO_BUFFER_SIZE:Int
    private var audio:AudioModel
    private var graph:MetalGraph?
    
    // initialize the variables
    init(viewGraph: MetalGraph?) {
        AUDIO_BUFFER_SIZE = 1024 * 16 // size of input buffer
        audio = AudioModel(buffer_size: AUDIO_BUFFER_SIZE) // create audio model
        graph = viewGraph // set graph to graph from view controller for update
    }
    
    // start the audio processing
    func start() {
        let serialQueue = DispatchQueue(label: "serial")
        serialQueue.sync { // put processing on serial queue
            audio.startMicrophoneProcessing(withFps: 10)
            audio.play()
            
            Timer.scheduledTimer(timeInterval: 0.05, target: self,
                selector: #selector(self.updateGraph),
                userInfo: nil,
                repeats: true)
        }
    }
    
    // pause audio processing
    func pause() {
        self.audio.pause()
    }
//
    @objc
    func getMaxes() -> ([Float]) { // return the calculated frequencies for the loundest sounds
        return self.audio.maxFreqs
    }
    
    @objc
    func updateGraph(){ // update the graphs to display the latest data
        self.graph?.updateGraph(
            data: self.audio.fftData,
            forKey: "fft"
        )

        self.graph?.updateGraph(
            data: self.audio.timeData,
            forKey: "time"
        )
        
    }
}


