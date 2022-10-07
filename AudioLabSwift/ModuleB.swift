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
    
    // Outlets to control the labels and sliders
    @IBOutlet weak var sliderLabel: UILabel!
    @IBOutlet weak var hertzSlider: UISlider!
    @IBOutlet weak var movementLabel: UILabel!
    
    // Timer in order to constantly update graphs
    private var timer:Timer = Timer()
    let audio = AudioModel(buffer_size: AUDIO_BUFFER_SIZE)
    
    // Lazy instantiation of grpah
    lazy var graph:MetalGraph? = {
        return MetalGraph(mainView: self.view)
    }()
    
    var sumLeft:Float = 0.0 // Sum of the left-most portion of the graph
    var sumRight:Float = 0.0 // Sum of the right-most portion of the graph
    var averageCount = 0 // Count of the averages
    var targetPeakLeft:Float = 0 // Target peak for the left side of the graph (to compare with the averages)
    var targetPeakRight:Float = 0   // Target peak for the right side of the graph (to compare with the averages)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // FOR SLIDER INITIALIZATION
        hertzSlider.minimumValue = 15000;
        hertzSlider.maximumValue = 20000;
        movementLabel.text = "Please move the slider"
        hertzSlider.value = 15000; // Set original slider value
        
        // add in graphs for display
        graph?.addGraph(withName: "fft",
                        shouldNormalize: true,
                        numPointsInGraph: AUDIO_BUFFER_SIZE/2)
        graph?.addGraph(withName: "time",
            shouldNormalize: false,
            numPointsInGraph: AUDIO_BUFFER_SIZE)
        
        // Start processing and playing the specific value (from slider)
        audio.startMicrophoneProcessing(withFps: 10)
        audio.startProcessingSinewaveForPlayback(withFreq: hertzSlider.value)
        audio.play()
        
        // run the loop for updating the graph peridocially
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self,
            selector: #selector(self.updateGraph),
            userInfo: nil,
            repeats: true)

    }
    
    // Action that changes the value of what is playing via the slider
    @IBAction func SliderAction(_ sender: Any) {
        sliderLabel.text = String(hertzSlider.value) + " Hz";
        sumLeft = 0
        sumRight = 0
        averageCount = 0
        movementLabel.text = "Please be still"
        audio.startProcessingSinewaveForPlayback(withFreq: hertzSlider.value)
        audio.play()
    }
    
    // Function to update both graphs on the screen
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
        
        // Starts the counting of averages to create a baseline to compare to
        if averageCount < 100 {
            let response = audio.getGesture(setHertz: hertzSlider.value)
            sumLeft += response.0
            sumRight += response.1
            averageCount += 1
        }
        // If there are enough averages to make a baseline, craete the target peaks
        else if averageCount == 100 {
            targetPeakLeft = sumLeft/100
            targetPeakRight = sumRight/100
            averageCount+=1
        }
        // With the baselines ready, we start taking inputs to measure Doppler Effect
        else {
            let currentMovementValue = audio.getGesture(setHertz: hertzSlider.value) // Stores microphone input in Hz
            let changeLeftPeak = abs(currentMovementValue.0 - targetPeakLeft) // Holds the difference in the left input and baseline
            let changeRightPeak = abs(currentMovementValue.1 - targetPeakRight) // Holds the difference in right input and baseline
            let changePeak = abs(changeLeftPeak - changeRightPeak) // Holds the difference in the Left and Right Peaks
            
            // Prints the values to the console to track changes
            print("Change Left, Change Right")
            print(changeLeftPeak, changeRightPeak)

           // FOR STILLNESS (There is no dramatic detectable movement)
            if changeLeftPeak == changeRightPeak || changePeak <= 0.07 {
                movementLabel.text = "Still"

            // MOVING AWAY (The hand is pulling away from the phone)
            } else if changeLeftPeak > changeRightPeak{
                movementLabel.text = "Moving out"

            // MOVING CLOSER (The hand is moving into the phone)
            } else if changeRightPeak > changeLeftPeak{
                movementLabel.text = "Moving in"
            } else {
                movementLabel.text = "This is literally impossible"
            }
            
        }

    }
    
    // Stops the playing and processing of the sine values when leaving Module B's view
    override func viewDidDisappear(_ animated: Bool){
        super.viewDidDisappear(animated)
        audio.startProcessingSinewaveForPlayback(withFreq: 0)
        audio.pause()
        timer.invalidate()
    }
}
