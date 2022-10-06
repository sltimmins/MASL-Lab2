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
    var sum:Float = 0.0
    var averageCount = 0
    var targetPeak:Float = 0
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
        sum = 0
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
            sum += audio.getGesture(setHertz: hertzSlider.value)
            averageCount += 1
        }
        
        else if averageCount == 100 {
            targetPeak = sum/100
            averageCount+=1
        }
        
        else {
            print("current Movement")
            let currentMovementValue = audio.getGesture(setHertz: hertzSlider.value)
            print(currentMovementValue)
            if currentMovementValue > targetPeak + 5 {
                movementLabel.text = "moving up"
            }
            else if currentMovementValue < targetPeak - 5 {
                movementLabel.text = "moving down"
            }
            else{
                movementLabel.text = "still"
            }
        }
        print("sum")
        print(sum)
        print("targetPeak")
        print(targetPeak)
    }
    
    override func viewDidDisappear(_ animated: Bool){
        super.viewDidDisappear(animated)
        audio.pause()
        timer.invalidate()
    }
}
