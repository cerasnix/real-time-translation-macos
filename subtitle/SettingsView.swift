import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("enableFeatureX") private var enableFeatureX = false
    @AppStorage("selectedOption") private var selectedOption = 0
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    private let options = ["Option 1", "Option 2", "Option 3"]

    var body: some View {
        Form {
            Section(header: Text("General")) {
                Toggle("Enable Feature X", isOn: $enableFeatureX)
                Picker("Select an Option", selection: $selectedOption) {
                    ForEach(0..<options.count, id: \.self) { index in
                        Text(options[index]).tag(index)
                    }
                }
                .pickerStyle(PopUpButtonPickerStyle())
            }
            Section(header: Text("Notifications")) {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}

struct GeneralSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        GeneralSettingsView()
    }
}
