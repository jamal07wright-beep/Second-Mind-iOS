//
// RootView.swift
//
// Four tabs: Listen (Stage 2 switches), Read (Stage 1), Notes (talks and
// the Obsidian graph), Settings. Only one of Listen or Read runs at a time.
//

import SwiftUI

struct RootView: View {
  let state: AppState
  let keychainWorks: Bool
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TabView {
      ListenView(listen: state.listen, ai: state.ai, reading: state.reading, coach: state.coach)
        .tabItem { Label("Listen", systemImage: "ear") }
      CoachView(coach: state.coach, listen: state.listen, reading: state.reading)
        .tabItem { Label("Coach", systemImage: "gamecontroller") }
      ContentView(
        connection: state.connection,
        reading: state.reading,
        practice: state.practice,
        keychainWorks: keychainWorks
      )
      .tabItem { Label("Read", systemImage: "text.viewfinder") }
      NotesView(graph: state.graph, ai: state.ai)
        .tabItem { Label("Notes", systemImage: "point.3.connected.trianglepath.dotted") }
      SettingsView(ai: state.ai, listen: state.listen, graph: state.graph)
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .tint(.indigo)
    .onChange(of: state.reading.isOn) { _, on in
      if on {
        state.listen.stop()
        state.coach.stop()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // Any finished day that hasn't become notes yet gets built now.
      if phase == .active, !state.listen.isOn {
        Task { await state.graph.buildPending(includeToday: false) }
      }
    }
  }
}
