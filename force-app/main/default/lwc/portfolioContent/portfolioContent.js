/**
 * Everything the portfolio page says, in one file. This is the file to edit: the components only
 * lay out what they are handed, and a section with nothing to show is left out of the page and out
 * of the navigation, so the page can grow one entry at a time.
 *
 * The page is a showcase for projects, and it is deliberately not a second résumé. Work history,
 * skills and certifications live on the résumé and on LinkedIn, and they are linked from here
 * rather than copied, so there is one place to keep them current. What each project was built with
 * shows on its own card, where it is evidence rather than a list.
 *
 * To finish the template, replace the placeholders. Search this file for "example.com", "Your Name"
 * and "Your next project", which are the values that are not yours yet.
 *
 * - A link with no url is skipped. A section whose list is empty is skipped.
 * - PROFILE.photo and each media file are file names inside the portfolio_assets static resource
 *   (force-app/main/default/staticresources/portfolio_assets). Add the picture there and name it
 *   here; an empty PROFILE.photo shows the initials instead.
 * - RESUME.url should be a link that keeps pointing at the newest file, such as a shared file you
 *   replace in place, so the page never needs a deploy for a new version. Empty hides the buttons.
 * - Links open in a new tab when they start with http, and in the mail app when they start with
 *   mailto:. portfolioContent.test.js refuses anything else, so a typo fails a test, not a visitor.
 */

export const PROFILE = {
  name: "Your Name",
  headline: "Salesforce Developer",
  intro:
    "I design and build Salesforce solutions end to end - Apex, Lightning Web Components, integrations and Experience Cloud sites - and I ship them with the tests, docs and deploy path they need to be trusted. The work is below, running, so you can see it rather than read about it.",
  location: "City, State",
  availability: "Open to new opportunities",
  photo: "profile-placeholder.svg"
};

export const RESUME = {
  label: "Résumé",
  url: "https://example.com/your-resume.pdf"
};

/** icon is one of the names in portfolioIcon: github, linkedin, trailhead, mail. */
export const PROFILE_LINKS = [
  {
    id: "linkedin",
    label: "LinkedIn",
    icon: "linkedin",
    url: "https://www.linkedin.com/in/your-handle"
  },
  {
    id: "github",
    label: "GitHub",
    icon: "github",
    url: "https://github.com/your-handle"
  },
  {
    id: "trailhead",
    label: "Trailhead",
    icon: "trailhead",
    url: "https://www.salesforce.com/trailblazer/your-handle"
  },
  {
    id: "email",
    label: "Email",
    icon: "mail",
    url: "mailto:you@example.com"
  }
];

/** The line under "Projects". Say what the labels on the cards mean. */
export const PROJECTS_INTRO =
  "Most of these are running right now. Each card says how much of it you can use, and what is worth trying.";

/**
 * How far a visitor can go with a project, which the card shows as a label:
 *   interactive  they can use it and change what they see
 *   view         it is live, and they can browse it, but nothing they do changes it
 *   video        a recorded walkthrough
 *   screenshots  no live version
 * "interactive" and "view" must have a link of kind demo, and the content test checks it, so a
 * card never promises a live version it does not link to. Leave access out to show no label.
 *
 * tryIt is one or two sentences of what to do with it. links[].kind picks the icon: demo, source,
 * or anything else for a plain arrow; the first demo link becomes the card's button. The first
 * project marked featured is shown wide, above the rest.
 *
 * media is optional. device is "desktop" or "phone", and alt is required: it is what a visitor who
 * cannot see the picture is told.
 */
export const PROJECTS = [
  {
    id: "portfolio-hq",
    featured: true,
    title: "Portfolio HQ",
    summary:
      "Two-way sync between a Salesforce org and two work trackers, Jira and Asana, with a Kanban board for the team and a read-only public board for anyone with the link. Built in ten numbered builds, with a separate guest-safe controller so that read-only is a property of the code, and a full Apex and Jest test suite.",
    access: "view",
    tryIt:
      "Switch between Tasks and Epics, filter by source, sort by due date or priority, and open any card. The board refreshes itself every 30 seconds while you look.",
    media: [
      {
        file: "portfolio-hq-desktop.png",
        device: "desktop",
        alt: "The public board on a desktop screen: controls for view, source and sort above three columns of work items, each card marked with the tracker it came from."
      },
      {
        file: "portfolio-hq-phone.png",
        device: "phone",
        alt: "The same board on a phone: one column at a time, with arrows to move between them."
      }
    ],
    tags: [
      "Apex",
      "Queueable Apex",
      "Platform Events",
      "Change Data Capture",
      "Lightning Web Components",
      "Experience Cloud (LWR)",
      "Named Credentials"
    ],
    links: [
      {
        kind: "demo",
        label: "Open the live board",
        url: "https://orgfarm-23f9e52958-dev-ed.develop.my.site.com/neoGeoTest/work-item-board"
      },
      {
        kind: "source",
        label: "Source",
        url: "https://github.com/neogeoaidev-spec/neoGeoDevHub"
      },
      {
        kind: "writeup",
        label: "Code tour",
        url: "https://github.com/neogeoaidev-spec/neoGeoDevHub/blob/main/docs/projects/01-workflow-board/tour/README.md"
      }
    ]
  },
  {
    id: "next-project",
    featured: false,
    title: "Your next project",
    summary:
      "A sentence or two on what it does and why you built it. Add a screenshot, a live demo link and the access label when there is a demo.",
    access: "screenshots",
    tags: ["Apex", "Flow"],
    links: [{ kind: "source", label: "Source", url: "" }]
  },
  {
    id: "another-project",
    featured: false,
    title: "Another project",
    summary:
      "Projects without links or pictures still show, so a write-up can come later.",
    tags: ["LWC"],
    links: []
  }
];

export const ABOUT = {
  summary: [
    "I'm a Salesforce developer who likes turning messy, multi-system processes into something a team can trust. My work spans Apex, Lightning Web Components, integrations and Experience Cloud, and I care as much about the tests and the deploy path as about the feature.",
    "Add a second paragraph here: what you are working toward, the kind of team you do your best work on, and one thing you do outside of work. My full history is on my résumé and LinkedIn."
  ]
};

export const CONTACT = {
  heading: "Let's build something",
  text: "I'm always glad to talk about a Salesforce project, a role, or a hard integration. The quickest way to reach me is email."
};
