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
  name: "Giovanni Mueco",
  headline: "Salesforce Developer",
  intro:
    "2+ years building with Apex, LWC, Flow, and integrations. I've owned large-scale unit-testing and legacy-migration projects, and I work directly with stakeholders to deliver solutions people actually adopt. I use AI tools like Claude Code to ship faster without cutting corners on security.",
  location: "Anaheim, California",
  availability: "Open to new opportunities",
  photo: "profile.webp",
  photoFallback: "profile.jpg"
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
    url: "https://www.linkedin.com/in/giovanni-mueco-419708228"
  },
  {
    id: "github",
    label: "GitHub",
    icon: "github",
    url: "https://github.com/geonidas"
  },
  {
    id: "trailhead",
    label: "Trailhead",
    icon: "trailhead",
    url: "https://www.salesforce.com/trailblazer/gmueco"
  },
  {
    id: "email",
    label: "Email",
    icon: "mail",
    url: "mailto:giovannimueco25@gmail.com"
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
    title: "Unified Cross-Platform Project Tracker",
    summary:
      "Sometimes you or your team might want to be able to see items from both Jira and Asana in one place within Salesforce, so I built a two-way sync that puts both on one Salesforce Kanban board. I actually use it myself, and there's also a demo version that uses a separate guest-safe controller accessing live org, Jira, and Asana data so you can take a look at what I'm currently working on.",
    access: "view",
    tryIt:
      "Switch between Tasks and Epics, filter by source, sort by due date or priority, and open any card. The board refreshes itself every 30 seconds while you look. Note that because this is live data available for anyone to see, it is read-only. The one I use is much more functional!",
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
        url: "https://orgfarm-7c9ef0e658-dev-ed.develop.my.site.com/neoGeoTest/work-item-board"
      },
      {
        kind: "source",
        label: "Source",
        url: "https://github.com/geonidas/PortfolioHQ-DE-Org/blob/main/docs/projects/01-workflow-board/README.md"
      },
      {
        kind: "writeup",
        label: "Code tour",
        url: "https://github.com/geonidas/PortfolioHQ-DE-Org/blob/main/docs/projects/01-workflow-board/tour/README.md"
      }
    ]
  },
  {
    id: "next-project",
    featured: false,
    title: "Agentforce Chatbot For This Portfolio",
    summary:
      "Agentforce is quickly becoming the face of modern Salesforce development. I think it would be a great addition to this page, so it could answer any quick questions you might have for me!",
    //access: "screenshots",
    tags: ["Apex", "Flow"],
    links: [{ kind: "source", label: "Source", url: "" }]
  },
  {
    id: "another-project",
    featured: false,
    title: "Mortgage Rate Calculator",
    summary:
      "A live-rate mortgage payment estimator added to the Property record page, pulling daily interest rates from the FRED API. Developed for the DreamHouse Real Estate Salesforce Org.",
    tags: ["LWC", "API"],
    links: [
      {
        kind: "source",
        label: "Source",
        url: "https://github.com/geonidas/Geos-DreamHouse-Repo/blob/main/docs/mortgage-calculator.md"
      }
    ]
  }
];

export const ABOUT = {
  summary: [
    "At my core, I'm just a nerd who loves breaking down complicated technologies and concepts into simple terms anyone can understand. This is what defines my personal approach to software development. I enjoy learning about new tools that help make my own workflows more efficient. For example, the current AI boom has been incredibly fascinating to me!", 
    "As for hobbies, I love reading books from thought-provoking fictional stories, to non-fiction books that expand the breadth of my knowledge of our world. I'm an on-and-off electric guitar and music theory learner. I also love playing video games and watching popular TV shows, anime and movies (I've been on a Marvel kick lately)."
  ]
};

export const CONTACT = {
  heading: "Let's build something",
  text: "I'm always glad to talk about a Salesforce project, a role, or a hard integration. The quickest way to reach me is email."
};
