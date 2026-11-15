import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { appCheckOption } from "../src/config";
import { parseImportedSchool, schoolKind, searchRecordFrom } from "../src/schools/catalog";

describe("appCheckOption (no deploy-log flood)", () => {
  const param = { name: "ENFORCE_APP_CHECK" };
  it("passes a plain true while firebase deploy loads the code", () => {
    assert.equal(appCheckOption(param, { FUNCTIONS_CONTROL_API: "true" }), true);
  });
  it("passes the parameter itself at runtime", () => {
    assert.equal(appCheckOption(param, {}), param);
    assert.equal(appCheckOption(param, { FUNCTIONS_CONTROL_API: "false" }), param);
  });
});

describe("school kinds", () => {
  it("keeps university (switch off by default in the import) and maps unknown kinds to school", () => {
    assert.equal(schoolKind("kindergarten"), "kindergarten");
    assert.equal(schoolKind("university"), "university");
    assert.equal(schoolKind("college"), "school");
    assert.equal(schoolKind(undefined), "school");
  });
  it("imports and indexes a university entry with its kind", () => {
    const parsed = parseImportedSchool({
      id: "osm-n1",
      source: "osm",
      sourceId: "n1",
      sourceKeys: ["osm:n1"],
      nameAr: "جامعة القاهرة",
      nameEn: "Cairo University",
      kind: "university",
      governorate: "giza",
      governorateMethod: "boundary",
      city: "Giza",
      cityAr: "الجيزة",
      location: { lat: 30.026, lng: 31.208 },
    });
    assert.equal(parsed.kind, "university");
    const record = searchRecordFrom("osm-n1", { nameAr: "جامعة القاهرة", nameEn: "Cairo University", kind: "university", governorate: "giza", status: "active" });
    assert.equal(record?.kind, "university");
  });
});
