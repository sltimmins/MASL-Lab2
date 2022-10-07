//
//  ViewController.swift
//  AudioLabSwift
//
//  Created by Eric Larson 
//  Copyright © 2020 Eric Larson. All rights reserved.
//
// Sam Timmins, Wyatt Saltzman, Kevin Leong, Caleb Moore

import UIKit
import Metal


let AUDIO_BUFFER_SIZE = 1024*16
let AUDIO_BUFFER_SIZE_B = 1024 * 4;

class ViewController: UIViewController {

    
//    let audio = AudioModel(buffer_size: AUDIO_BUFFER_SIZE)
    lazy var graph:MetalGraph? = {
        return MetalGraph(mainView: self.view)
    }()
    
    lazy var analyzer:AnalyzerModel = {
        return AnalyzerModel(viewGraph: graph)
    }()
    let arr = Array(1...100)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // add in graphs for display
        graph?.addGraph(withName: "fft",
                        shouldNormalize: true,
                        numPointsInGraph: AUDIO_BUFFER_SIZE / 2)

        graph?.addGraph(withName: "time",
            shouldNormalize: false,
            numPointsInGraph: AUDIO_BUFFER_SIZE)
        
        // start the analyzer model
        analyzer.start()
        
        // update the view every half second
        Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(self.getMaxes), userInfo: nil, repeats: true)
       
    }
    
    override func viewDidDisappear(_ animated: Bool){
        super.viewDidDisappear(animated)
        self.analyzer.pause()
    }
    
    @objc
    func getMaxes() {
        // output the frequencies to the view
        let maxFreqs = self.analyzer.getMaxes()
        max1.text = String(maxFreqs[0] + 25) + " Hz"
        max2.text = String(maxFreqs[1] + 25) + " Hz"
    }
    
    @IBOutlet weak var max1: UILabel!
    @IBOutlet weak var max2: UILabel!
}

