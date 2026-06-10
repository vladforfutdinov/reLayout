// GitHub owner/repo for the About links (tray + Settings SysLink). CI overwrites
// this file with the building repository's slug (vars.RELAYOUT_REPO_SLUG, falling
// back to github.repository) before `swift build` — same pattern as Version.swift.
// This committed neutral default is what local builds compile against.
let repoSlug = "example/reLayout"
