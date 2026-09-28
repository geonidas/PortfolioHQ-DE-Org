import { createElement } from "lwc";
import BoardToolbar from "c/boardToolbar";

const OPTIONS = [
  { value: "", label: "All sources" },
  { value: "Source A", label: "Source A" },
  { value: "Source B", label: "Source B" }
];

function mount(props) {
  const element = createElement("c-board-toolbar", { is: BoardToolbar });
  Object.assign(
    element,
    { view: "tasks", source: "", sourceOptions: OPTIONS },
    props
  );
  document.body.appendChild(element);
  return element;
}

const select = (element, name) =>
  element.shadowRoot.querySelector(`select[data-filter="${name}"]`);

function choose(element, name, value) {
  const control = select(element, name);
  control.value = value;
  control.dispatchEvent(new CustomEvent("change"));
}

describe("c-board-toolbar", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("labels every control visibly, in order: View, Source, Sort", () => {
    const element = mount();
    const labels = Array.from(
      element.shadowRoot.querySelectorAll(".field-label")
    ).map((label) => label.textContent);
    // toStrictEqual, and every control named: a fourth control fails this.
    expect(labels).toStrictEqual(["View", "Source", "Sort"]);
    // Each select sits inside its label, which names it without an id.
    expect(select(element, "view").closest("label")).not.toBeNull();
    expect(select(element, "source").closest("label")).not.toBeNull();
    expect(select(element, "sort").closest("label")).not.toBeNull();
  });

  it("offers Due date, then Priority, and opens on Due date", () => {
    const element = mount();
    expect(
      Array.from(select(element, "sort").options).map((o) =>
        o.textContent.trim()
      )
    ).toStrictEqual(["Due date", "Priority"]);
    expect(select(element, "sort").value).toBe("due");
  });

  it("shows the current sort and raises sortchange with the chosen value", () => {
    const element = mount({ sort: "priority" });
    expect(select(element, "sort").value).toBe("priority");
    const onSort = jest.fn();
    element.addEventListener("sortchange", onSort);
    choose(element, "sort", "due");
    expect(onSort.mock.calls[0][0].detail).toEqual({ value: "due" });
  });

  it("offers Tasks and Epics, and the sources it is given", () => {
    const element = mount();
    const values = (name) =>
      Array.from(select(element, name).options).map((o) =>
        o.textContent.trim()
      );
    expect(values("view")).toEqual(["Tasks", "Epics"]);
    expect(values("source")).toEqual(["All sources", "Source A", "Source B"]);
  });

  it("shows the current choices", () => {
    const element = mount({ view: "epics", source: "Source B" });
    expect(select(element, "view").value).toBe("epics");
    expect(select(element, "source").value).toBe("Source B");
  });

  it("raises viewchange and sourcechange with the chosen value", () => {
    const element = mount();
    const onView = jest.fn();
    const onSource = jest.fn();
    element.addEventListener("viewchange", onView);
    element.addEventListener("sourcechange", onSource);

    choose(element, "view", "epics");
    choose(element, "source", "Source A");

    expect(onView.mock.calls[0][0].detail).toEqual({ value: "epics" });
    expect(onSource.mock.calls[0][0].detail).toEqual({ value: "Source A" });
  });

  it("has no button", () => {
    expect(mount().shadowRoot.querySelector("button")).toBeNull();
  });

  it("is accessible", async () => {
    await expect(mount()).toBeAccessible();
  });
});
