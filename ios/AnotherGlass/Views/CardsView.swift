import SwiftUI

struct CardsView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var server: GlassServer
    @FocusState private var focusedField: Field?
    private enum Field { case title, message }

    init(model: CompanionModel) {
        self.model = model
        server = model.server
    }

    var body: some View {
        GlassPage {
            GlassPageHeading(title: "Cards", subtitle: "A note, an address, a thought. Right in view.")

            GlassSection(title: "On your Glass") {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.cardTitle.isEmpty ? "Something to keep in view" : model.cardTitle)
                            .font(.title2.weight(.medium)).lineLimit(3)
                        Text(model.cardText.isEmpty ? "Your message will appear here" : model.cardText)
                            .font(.body).foregroundStyle(GlassStyle.secondary).lineLimit(5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    HStack {
                        GlassStatus(text: "AnotherGlass")
                        Spacer()
                        Image(systemName: "eyeglasses").foregroundStyle(GlassStyle.muted).accessibilityHidden(true)
                    }
                }
                .padding(24)
                .background(.black, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(GlassStyle.line, lineWidth: 1) }
            }

            GlassSection(title: "Compose") {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Title").font(.subheadline).foregroundStyle(GlassStyle.secondary)
                            Spacer()
                            Text("\(model.cardTitle.count)/120").font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                                .accessibilityLabel("\(model.cardTitle.count) of 120 title characters")
                        }
                        TextField("Card title", text: $model.cardTitle)
                            .focused($focusedField, equals: .title)
                            .submitLabel(.next).onSubmit { focusedField = .message }
                            .modifier(GlassFieldModifier())
                            .onChange(of: model.cardTitle) { _, value in
                                if value.count > 120 { model.cardTitle = String(value.prefix(120)) }
                            }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Message").font(.subheadline).foregroundStyle(GlassStyle.secondary)
                            Spacer()
                            Text("\(model.cardText.count)/4,000").font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                                .accessibilityLabel("\(model.cardText.count) of 4,000 message characters")
                        }
                        TextField("What would you like to send?", text: $model.cardText, axis: .vertical)
                            .lineLimit(4...10).focused($focusedField, equals: .message)
                            .modifier(GlassFieldModifier())
                            .onChange(of: model.cardText) { _, value in
                                if value.count > 4000 { model.cardText = String(value.prefix(4000)) }
                            }
                    }
                    Button { focusedField = nil; model.sendCard() } label: {
                        Label("Send to Glass", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                    .disabled(!server.isConnected || (model.cardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.cardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }

            if !server.isConnected {
                Button { model.selectedTab = 0 } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "eyeglasses").accessibilityHidden(true)
                        Text("Connect Glass to send your card").multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .font(.subheadline).foregroundStyle(GlassStyle.secondary).frame(minHeight: 44)
                }
            }

            if !model.cards.isEmpty {
                GlassSection(title: "Sent this session", detail: "Sent to the connection; Glass does not confirm delivery. Remove a card using the bundled Explorer APK. History lasts for this session only.") {
                    LazyVStack(spacing: 12) {
                        ForEach(model.cards) { card in
                            GlassPanel {
                                HStack(alignment: .top) {
                                    Text(card.date, style: .time).font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                                    Spacer()
                                    Button(role: .destructive) { model.removeCard(card) } label: {
                                        Image(systemName: "trash").frame(width: 44, height: 44)
                                    }
                                    .accessibilityLabel("Remove \(card.title.isEmpty ? "card" : card.title) from Glass")
                                    .disabled(!server.isConnected)
                                }
                                if !card.title.isEmpty { Text(card.title).font(.headline.weight(.medium)) }
                                if !card.text.isEmpty { Text(card.text).font(.subheadline).foregroundStyle(GlassStyle.secondary).lineLimit(3) }
                            }
                        }
                    }
                }
            }
        }
    }
}
