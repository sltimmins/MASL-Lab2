//
//  ModuleB.swift
//  AudioLabSwift
//
//  Created by Sammy Timmins on 10/5/22.
//  Copyright © 2022 Eric Larson. All rights reserved.
//

import Foundation
import UIKit

class ModuleB : UIViewController {
    
    @IBOutlet weak var sliderLabel: UILabel!
    @IBOutlet weak var hertzSlider: UISlider!
    @IBOutlet weak var movementLabel: UILabel!
    
    private var timer:Timer = Timer()
    let audio = AudioModel(buffer_size: AUDIO_BUFFER_SIZE)
    lazy var graph:MetalGraph? = {
        return MetalGraph(mainView: self.view)
    }()
    var sumLeft:Float = 0.0
    var sumRight:Float = 0.0
    var averageCount = 0
    var targetPeakLeft:Float = 0
    var targetPeakRight:Float = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // FOR SLIDER
        hertzSlider.minimumValue = 15;
        hertzSlider.maximumValue = 7000;
        movementLabel.text = "Please move the slider"
        hertzSlider.value = 15;
        // add in graphs for display
        graph?.addGraph(withName: "fft",
                        shouldNormalize: true,
                        numPointsInGraph: AUDIO_BUFFER_SIZE/2)
        graph?.addGraph(withName: "time",
            shouldNormalize: false,
            numPointsInGraph: AUDIO_BUFFER_SIZE)
        
        audio.startMicrophoneProcessing(withFps: 10)
        audio.startProcessingSinewaveForPlayback(withFreq: hertzSlider.value)
        audio.play()
        
        // run the loop for updating the graph peridocially
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self,
            selector: #selector(self.updateGraph),
            userInfo: nil,
            repeats: true)

    }
    

    @IBAction func SliderAction(_ sender: Any) {
        sliderLabel.text = String(hertzSlider.value);
//        audio.getSample()
        sumLeft = 0
        sumRight = 0
        averageCount = 0
        movementLabel.text = "Please be still"
    }
    
    @objc
    func updateGraph(){
        self.graph?.updateGraph(
            data: self.audio.fftData,
            forKey: "fft"
        )
        
        self.graph?.updateGraph(
            data: self.audio.timeData,
            forKey: "time"
        )
        
        if averageCount < 100 {
            let response = audio.getGesture(setHertz: hertzSlider.value)
            sumLeft += response.0
            sumRight += response.1
            averageCount += 1
        }
        
        else if averageCount == 100 {
            targetPeakLeft = sumLeft/100
            targetPeakRight = sumRight/100
            averageCount+=1
        }
        
        else {
            print("current Movement")
            let currentMovementValue = audio.getGesture(setHertz: hertzSlider.value)
            print(currentMovementValue)
            if currentMovementValue.1 > currentMovementValue.0 {
                movementLabel.text = "ONE BIGGER"
            }
            else if currentMovementValue.1 < currentMovementValue.0 {
                movementLabel.text = "one smaller"
            }
            else{
                movementLabel.text = "still"
            }
        }
        print("sums")
        print(sumLeft, sumRight)
        print("targetPeaks")
        print(targetPeakLeft, targetPeakRight)
    }
    
    override func viewDidDisappear(_ animated: Bool){
        super.viewDidDisappear(animated)
        audio.pause()
        timer.invalidate()
    }
}
