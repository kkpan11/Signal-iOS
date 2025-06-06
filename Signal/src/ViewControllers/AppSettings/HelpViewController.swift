//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI

final class HelpViewController: OWSTableViewController2 {

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTableContents()
    }

    private func updateTableContents() {
        let helpTitle = CommonStrings.help
        let supportCenterLabel = OWSLocalizedString("HELP_SUPPORT_CENTER",
                                                   comment: "Help item that takes the user to the Signal support website")
        let contactLabel = OWSLocalizedString("HELP_CONTACT_US",
                                             comment: "Help item allowing the user to file a support request")
        let localizedSheetTitle = OWSLocalizedString("EMAIL_SIGNAL_TITLE",
                                                    comment: "Title for the fallback support sheet if user cannot send email")
        let localizedSheetMessage = OWSLocalizedString("EMAIL_SIGNAL_MESSAGE",
                                                      comment: "Description for the fallback support sheet if user cannot send email")

        let contents = OWSTableContents(title: helpTitle)

        let helpSection = OWSTableSection()
        helpSection.add(.disclosureItem(
            withText: supportCenterLabel,
            actionBlock: { [weak self] in
                let vc = SFSafariViewController(url: SupportConstants.supportURL)
                self?.present(vc, animated: true, completion: nil)
            }
        ))
        helpSection.add(.disclosureItem(
            withText: contactLabel,
            actionBlock: {
                guard ComposeSupportEmailOperation.canSendEmails else {
                    let fallbackSheet = ActionSheetController(title: localizedSheetTitle,
                                                              message: localizedSheetMessage)
                    let buttonTitle = OWSLocalizedString("BUTTON_OKAY", comment: "Label for the 'okay' button.")
                    fallbackSheet.addAction(ActionSheetAction(title: buttonTitle, style: .default))
                    self.presentActionSheet(fallbackSheet)
                    return
                }
                let supportVC = ContactSupportViewController()
                let navVC = OWSNavigationController(rootViewController: supportVC)
                self.presentFormSheet(navVC, animated: true)
            }
        ))
        contents.add(helpSection)

        let loggingSection = OWSTableSection()
        loggingSection.headerTitle = OWSLocalizedString("LOGGING_SECTION", comment: "Title for the 'logging' help section.")
        loggingSection.footerTitle = OWSLocalizedString("LOGGING_SECTION_FOOTER", comment: "Footer for the 'logging' help section.")
        loggingSection.add(.item(
            name: OWSLocalizedString("SETTINGS_ADVANCED_SUBMIT_DEBUGLOG", comment: ""),
            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "submit_debug_log"),
            actionBlock: {
                DebugLogs.submitLogs(dumper: .fromGlobals())
            }
        ))
        contents.add(loggingSection)

        let aboutSection = OWSTableSection()
        aboutSection.headerTitle = OWSLocalizedString("ABOUT_SECTION_TITLE", comment: "Title for the 'about' help section")
        aboutSection.footerTitle = OWSLocalizedString(
            "SETTINGS_COPYRIGHT",
            comment: "Footer for the 'about' help section"
        )
        aboutSection.add(.copyableItem(
            label: OWSLocalizedString("SETTINGS_VERSION", comment: ""),
            value: AppVersionImpl.shared.prettyAppVersion
        ))
        aboutSection.add(.disclosureItem(
            withText: OWSLocalizedString("SETTINGS_LEGAL_TERMS_CELL", comment: ""),
            actionBlock: { [weak self] in
                let url = TSConstants.legalTermsUrl
                let vc = SFSafariViewController(url: url)
                self?.present(vc, animated: true, completion: nil)
            }
        ))
        contents.add(aboutSection)

        self.contents = contents
    }
}
