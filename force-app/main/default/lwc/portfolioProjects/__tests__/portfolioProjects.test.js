import { createElement } from "lwc";
import PortfolioProjects from "c/portfolioProjects";

const DESKTOP = {
  url: "/assets/big-desktop.png",
  device: "desktop",
  alt: "The board on a desktop"
};
const PHONE = {
  url: "/assets/big-phone.png",
  device: "phone",
  alt: "The board on a phone"
};

const PROJECTS = [
  {
    id: "small",
    featured: false,
    title: "Small one",
    summary: "A small project.",
    tags: ["Flow"],
    links: []
  },
  {
    id: "big",
    featured: true,
    title: "Big one",
    summary: "The main project.",
    access: "view",
    tryIt: "Filter it and open a card.",
    media: [DESKTOP, PHONE],
    tags: ["Apex", "LWC"],
    links: [
      { kind: "source", label: "Source", url: "https://example.com/src" },
      { kind: "demo", label: "Open it", url: "https://example.com/demo" },
      { kind: "writeup", label: "Write-up", url: "https://example.com/post" },
      { kind: "demo", label: "Not yet", url: "" }
    ]
  }
];

function mount(projects = PROJECTS, intro = "") {
  const element = createElement("c-portfolio-projects", {
    is: PortfolioProjects
  });
  element.projects = projects;
  element.intro = intro;
  document.body.appendChild(element);
  return element;
}

const card = (element, id) =>
  element.shadowRoot.querySelector(`[data-project="${id}"]`);

const withProject = (overrides) => [
  { ...PROJECTS[1], ...overrides },
  PROJECTS[0]
];

async function flush() {
  await Promise.resolve();
}

describe("c-portfolio-projects", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("puts the featured project first however the list is ordered, and badges it", () => {
    const element = mount();
    const ids = Array.from(
      element.shadowRoot.querySelectorAll("[data-project]")
    ).map((li) => li.dataset.project);
    expect(ids).toStrictEqual(["big", "small"]);
    expect(card(element, "big").classList).toContain("featured");
    expect(card(element, "big").querySelector(".badge").textContent).toBe(
      "Featured"
    );
    expect(card(element, "small").querySelector(".badge")).toBeNull();
  });

  it("does not reorder the array it was given", () => {
    const given = [...PROJECTS];
    mount(given);
    expect(given.map((p) => p.id)).toStrictEqual(["small", "big"]);
  });

  it("shows the title, the summary and the tags", () => {
    const big = card(mount(), "big");
    expect(big.querySelector(".title").textContent).toBe("Big one");
    expect(big.querySelector(".summary").textContent).toBe("The main project.");
    expect(
      Array.from(big.querySelectorAll(".chip")).map((c) => c.textContent)
    ).toStrictEqual(["Apex", "LWC"]);
  });

  it("shows the line under the heading only when there is one", () => {
    expect(
      mount(PROJECTS, "Most are live.").shadowRoot.querySelector("[data-intro]")
        .textContent
    ).toBe("Most are live.");
    expect(mount().shadowRoot.querySelector("[data-intro]")).toBeNull();
  });

  describe("media", () => {
    it("shows the screenshot in a browser frame and the phone beside it, each with its alt text", () => {
      const media = card(mount(), "big").querySelector("[data-media]");
      const desktop = media.querySelector(".desktop img");
      const phone = media.querySelector(".phone img");
      expect(desktop.getAttribute("src")).toBe("/assets/big-desktop.png");
      expect(desktop.getAttribute("alt")).toBe("The board on a desktop");
      expect(phone.getAttribute("src")).toBe("/assets/big-phone.png");
      expect(phone.getAttribute("alt")).toBe("The board on a phone");
      // The three lights of the frame are decoration, not content.
      expect(media.querySelector(".chrome").getAttribute("aria-hidden")).toBe(
        "true"
      );
    });

    it("leaves no media area for a project without pictures", () => {
      const small = card(mount(), "small");
      expect(small.querySelector("[data-media]")).toBeNull();
      expect(small.classList).not.toContain("has-media");
    });

    it("shows a phone on its own when there is no desktop picture", () => {
      const element = mount(withProject({ media: [PHONE] }));
      const media = card(element, "big").querySelector("[data-media]");
      expect(media.classList).toContain("phone-only");
      expect(media.querySelector(".desktop")).toBeNull();
      expect(media.querySelector(".phone img")).not.toBeNull();
    });

    it("drops a picture that fails to load, and the card closes up around it", async () => {
      const element = mount(withProject({ media: [DESKTOP] }));
      card(element, "big")
        .querySelector(".desktop img")
        .dispatchEvent(new CustomEvent("error"));
      await flush();
      expect(card(element, "big").querySelector("[data-media]")).toBeNull();
      expect(card(element, "big").classList).not.toContain("has-media");
    });

    it("drops only the picture that failed", async () => {
      const element = mount();
      card(element, "big")
        .querySelector(".phone img")
        .dispatchEvent(new CustomEvent("error"));
      await flush();
      const media = card(element, "big").querySelector("[data-media]");
      expect(media.querySelector(".desktop img")).not.toBeNull();
      expect(media.querySelector(".phone")).toBeNull();
    });
  });

  describe("how far a visitor can go", () => {
    const label = (element) => {
      const access = card(element, "big").querySelector("[data-access]");
      return access && access.textContent.trim();
    };

    it.each([
      ["interactive", "Interactive demo"],
      ["view", "Live, view-only"],
      ["video", "Video walkthrough"],
      ["screenshots", "Screenshots only"]
    ])("labels %s as %s", (access, expected) => {
      expect(label(mount(withProject({ access })))).toBe(expected);
    });

    it("styles each level by name, so the strongest promise looks the strongest", () => {
      const element = mount(withProject({ access: "interactive" }));
      expect(
        card(element, "big").querySelector("[data-access]").classList
      ).toContain("interactive");
    });

    it("shows no label for a project that does not say, or says something unknown", () => {
      expect(label(mount(withProject({ access: undefined })))).toBeNull();
      expect(label(mount(withProject({ access: "everything" })))).toBeNull();
    });

    it("says what is worth trying, when it says anything", () => {
      const big = card(mount(), "big").querySelector("[data-try-it]");
      expect(big.textContent).toContain("Filter it and open a card.");
      expect(card(mount(), "small").querySelector("[data-try-it]")).toBeNull();
    });
  });

  describe("links", () => {
    it("makes the demo the card's button, and lists the rest as links, skipping any with no url", () => {
      const big = card(mount(), "big");
      const button = big.querySelector("a.btn-primary");
      expect(button.getAttribute("href")).toBe("https://example.com/demo");
      expect(button.textContent).toContain("Open it");
      const others = Array.from(big.querySelectorAll("a.action"));
      expect(others.map((a) => a.getAttribute("href"))).toStrictEqual([
        "https://example.com/src",
        "https://example.com/post"
      ]);
    });

    it("opens every link in a new tab without handing it the opener", () => {
      Array.from(card(mount(), "big").querySelectorAll("a")).forEach((a) => {
        expect(a.getAttribute("target")).toBe("_blank");
        expect(a.getAttribute("rel")).toBe("noopener noreferrer");
      });
    });

    it("picks the icon by kind", () => {
      const big = card(mount(), "big");
      expect(big.querySelector("a.btn-primary c-portfolio-icon").name).toBe(
        "external"
      );
      expect(
        Array.from(big.querySelectorAll("a.action")).map(
          (a) => a.querySelector("c-portfolio-icon").name
        )
      ).toStrictEqual(["github", "arrow"]);
    });

    it("tells a screen reader which project each link belongs to", () => {
      const big = card(mount(), "big");
      [
        big.querySelector("a.btn-primary"),
        big.querySelector("a.action")
      ].forEach((a) =>
        expect(a.querySelector(".assistive").textContent.trim()).toBe(
          "(Big one, opens in a new tab)"
        )
      );
    });

    it("shows a card with no demo without a button, and one with no links without an actions row", () => {
      const noDemo = mount(
        withProject({
          links: [{ kind: "source", label: "Source", url: "https://e.com" }]
        })
      );
      expect(card(noDemo, "big").querySelector("a.btn-primary")).toBeNull();
      expect(card(noDemo, "big").querySelectorAll("a.action")).toHaveLength(1);
      expect(card(mount(), "small").querySelector(".actions")).toBeNull();
    });
  });

  it("is accessible, with pictures and without", async () => {
    await expect(mount(PROJECTS, "Most are live.")).toBeAccessible();
    await expect(mount([PROJECTS[0]])).toBeAccessible();
  });
});
