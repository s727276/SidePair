//
//  ContentView.swift
//  SidePair
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "checkmark.seal.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .font(.title)
                .padding()
            Text("Hello, world!")
                .font(.title)
                .padding()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
