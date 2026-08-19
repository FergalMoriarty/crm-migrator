"""
generate_source.py — produce one acquired agency's CSV export, deliberately messy.

WHAT THIS DOES
    Writes four CSVs to data/source/<agency_slug>/ modelling what a lettings
    agency actually hands over on acquisition: a dump out of their CRM, in their
    own column names, with their own conventions, and years of human data entry
    baked in.

WHY IT EXISTS AS A SEPARATE STEP
    Generating and loading are separate scripts on purpose. You can regenerate
    the data without touching the database, and reload the database without
    regenerating. If they were one script every reload would silently rewrite
    the fixture you were debugging against.

WHY A FIXED SEED
    Reproducibility is the whole point. A cleaning rule that fixes a defect you
    can no longer produce on demand is not a fix, it is a coincidence. Change
    SEED and every downstream test that asserts a specific count breaks — which
    is the correct, loud behaviour.

DECISION: messiness is *modelled*, not random
    Every defect below is a real convention or a real failure mode from a real
    export — Excel eating a leading zero from a phone number, a UTF-8 file read
    back as cp1252, an accounting package writing negatives in brackets.
    Random noise would be easy to generate and worthless to clean, because the
    cleaning rules you would write for it would not transfer to anything.
    ALTERNATIVE CONSIDERED: a library like Faker with corruption applied on top.
    Rejected — Faker gives plausible *clean* data, and the interesting half of
    this project is the dirt, which you would end up hand-writing anyway.

PHASE 2 NOTE
    Agency B lands here later as a second entry in AGENCIES, with genuinely
    incompatible conventions (different column names, different date order,
    different ID scheme) and some of the same landlords under different IDs.
    Only ever one agency's CSVs are loaded at a time — see load_source.py.
"""

from __future__ import annotations

import argparse
import csv
import io
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 20260819
RNG = random.Random(SEED)

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_ROOT = REPO_ROOT / "data" / "source"

AGENCY = {"slug": "harcourt_vine", "name": "Harcourt & Vine", "code": "HV"}

N_LANDLORDS = 150
N_PROPERTIES = 300
N_TENANCIES = 340
N_PAYMENTS = 1800

# Landlords who exist twice in this agency's own CRM under different refs.
# Same person, two records, contact details differing only in case/whitespace.
# This is the within-agency version of the problem; the cross-agency version
# arrives in phase 2. The intermediate layer has to survive both.
N_DUPLICATE_LANDLORDS = 4

# Properties pointing at a landlord ref that is not in landlords.csv, and
# tenancies pointing at a property ref that is not in properties.csv. Real
# exports do this constantly — the CRM had soft-deleted the parent, or the
# export ran against two tables at different times.
N_ORPHAN_PROPERTIES = 5
N_ORPHAN_TENANCIES = 6


# ---------------------------------------------------------------------------
# Messiness primitives
# ---------------------------------------------------------------------------

def mojibake(s: str) -> str:
    """Simulate a bad encoding round-trip: UTF-8 bytes decoded as cp1252.

    This is the single most common encoding failure in a CRM export — the file
    is UTF-8, something on the way out assumed Windows-1252, and 'Ó' becomes
    'Ã³' permanently. It matters here because it is *repairable* in staging
    (re-encode cp1252 -> decode utf-8) and that repair is worth writing.
    """
    return s.encode("utf-8").decode("cp1252", errors="replace")


def maybe(p: float) -> bool:
    return RNG.random() < p


EXCEL_EPOCH = date(1899, 12, 30)  # Excel's day 0, including the 1900 leap bug


def fmt_date(d: date | None) -> str:
    """One date, six ways. All six appear in one column of one export."""
    if d is None:
        return RNG.choice(["", "", "N/A", "-"])
    r = RNG.random()
    if r < 0.55:
        return d.strftime("%d/%m/%Y")          # UK default
    if r < 0.72:
        return d.isoformat()                   # someone exported properly
    if r < 0.82:
        return str((d - EXCEL_EPOCH).days)     # Excel serial, cell was General
    if r < 0.90:
        return d.strftime("%d-%m-%Y")
    if r < 0.96:
        return f"{d.day}/{d.month}/{str(d.year)[2:]}"  # D/M/YY
    return d.strftime("%d/%m/%Y %H:%M:%S")     # datetime in a date column


def fmt_money(x: float) -> str:
    """Currency as text, including accounting-style negatives in brackets."""
    if x < 0:
        neg = abs(x)
        return RNG.choice([f"({neg:,.2f})", f"-£{neg:,.2f}", f"-{neg:.2f}"])
    return RNG.choice([
        f"£{x:,.2f}", f"{x:,.2f}", f"£{x:.0f}", f"{x:.2f}",
        f"£ {x:,.2f}", f"{x:.0f}", f"GBP {x:,.2f}",
    ])


def fmt_phone(mobile: bool) -> str:
    """UK phone numbers in every form a spreadsheet and a human can produce.

    Note the bare '7700900123' form: Excel treated the cell as a number and ate
    the leading zero. You cannot tell that from a mangled number by looking at
    the value alone — you have to know the rule (10 digits starting 7 is a
    mobile missing its 0). 028 9649 6xxx is Ofcom's reserved drama range.
    """
    if maybe(0.06):
        return RNG.choice(["", "", "N/A", "n/a", "-", "unknown"])
    if mobile:
        n = f"7700900{RNG.randint(0, 999):03d}"
        return RNG.choice([
            f"0{n[:4]} {n[4:]}", f"0{n}", f"+44 {n[:4]} {n[4:]}",
            f"+44{n}", f"0044 {n}", n, f"0{n[:4]}-{n[4:]}", f" 0{n} ",
        ])
    n = f"96496{RNG.randint(0, 99):02d}"
    return RNG.choice([
        f"028 {n[:4]} {n[4:]}", f"028{n}", f"(028) {n[:4]} {n[4:]}",
        f"+44 28 {n[:4]} {n[4:]}", f"28 {n}",
    ])


PC_AREAS = ["BT1", "BT4", "BT7", "BT9", "BT12", "BT15", "BT17", "BT27",
            "BT38", "BT47", "M1", "LS6", "EH8"]


def fmt_postcode() -> str:
    out = f"{RNG.choice(PC_AREAS)} {RNG.randint(1, 9)}{RNG.choice('ABDEFGHJLNPQRSTUWXYZ')}{RNG.choice('ABDEFGHJLNPQRSTUWXYZ')}"
    r = RNG.random()
    if r < 0.20:
        return out.replace(" ", "")        # no space
    if r < 0.32:
        return out.lower()
    if r < 0.40:
        return out.replace(" ", "  ")      # double space
    if r < 0.46:
        return f" {out} "
    if r < 0.49:
        return out[:-1]                    # truncated — genuinely invalid
    return out


FIRST = ["Fiona", "Séamus", "Máire", "Conor", "Aoife", "Gareth", "Niamh",
         "Declan", "Sinéad", "Ruairí", "Hannah", "Tomás", "Ciara", "Peter",
         "Órla", "Stephen", "Bronagh", "Michael", "Caoimhe", "Alan"]
LAST = ["McAllister", "O'Neill", "Ó Súilleabháin", "Doherty", "Kavanagh",
        "Hetherington", "Ní Bhriain", "Magennis", "Cunningham", "Fitzsimons",
        "Boyd", "Ferguson", "MacGiolla", "Rafferty", "Weatherup", "Nesbitt"]
TITLES = ["MR", "MRS", "MS", "Dr", "Mr.", ""]


def fmt_name(first: str, last: str) -> str:
    """'SURNAME, First' and 'First Surname' in the same column, plus titles."""
    if maybe(0.08):
        # The accented names are where an encoding failure actually shows up,
        # and a mangled name is the hardest kind to spot by eye in a report.
        first, last = mojibake(first), mojibake(last)
    r = RNG.random()
    if r < 0.38:
        return f"{last.upper()}, {first}"
    if r < 0.46:
        return f"{last.upper()},{first}"          # no space after comma
    if r < 0.58:
        base = f"{first} {last}"
        t = RNG.choice(TITLES)
        return f"{t} {base}".strip()
    if r < 0.66:
        return f"{first} {last}".upper()
    if r < 0.72:
        return f"{first} {last}".lower()
    if r < 0.76:
        return f"{first}  {last} "                # doubled/trailing space
    return f"{first} {last}"


def fmt_email(first: str, last: str) -> str:
    if maybe(0.07):
        return RNG.choice(["", "", "n/a", "none", "-"])
    local = f"{first}.{last}".lower()
    local = (local.replace("'", "").replace(" ", "")
                  .replace("é", "e").replace("í", "i").replace("ó", "o")
                  .replace("á", "a").replace("ú", "u"))
    dom = RNG.choice(["gmail.com", "hotmail.co.uk", "btinternet.com",
                      "outlook.com", "yahoo.co.uk", "live.co.uk"])
    addr = f"{local}@{dom}"
    r = RNG.random()
    if r < 0.12:
        return addr.upper()
    if r < 0.22:
        return f" {addr} "
    if r < 0.28:
        return addr.capitalize()
    if r < 0.32:
        return f"{addr};"
    if r < 0.35:
        return f"{addr} / {local}@work.co.uk"     # two addresses, one column
    return addr


STREETS = ["Malone Road", "Ormeau Road", "Ravenhill Avenue", "Stranmillis Road",
           "Botanic Avenue", "Cregagh Road", "Antrim Road", "Lisburn Road",
           "University Street", "Donegall Pass", "Springfield Road", "Holywood Road"]
BUILDINGS = ["Rosemount House", "Elmwood Court", "The Gasworks", "Vine Mews",
             "Harcourt Point", "Camden Court"]
TOWNS = ["Belfast", "BELFAST", "belfast", "Lisburn", "Bangor", "Newtownabbey",
         "Carrickfergus", "Holywood", " Belfast"]


def fmt_address() -> tuple[str, str]:
    """Flat number sometimes in line 1, sometimes line 2, sometimes as '2/14'.

    This is why address parsing is best-effort. There is no rule that recovers
    the flat number from all four shapes without a PAF lookup, and pretending
    otherwise in a model is worse than admitting it in the README.
    """
    num = RNG.randint(1, 220)
    street = RNG.choice(STREETS)
    r = RNG.random()
    if r < 0.45:
        return f"{num} {street}", ""
    flat = RNG.randint(1, 12)
    if r < 0.60:
        return f"Flat {flat}, {num} {street}", ""
    if r < 0.72:
        return f"{num} {street}", f"Flat {flat}"
    if r < 0.84:
        return f"Apt {flat} {RNG.choice(BUILDINGS)}", f"{num} {street}"
    if r < 0.92:
        return f"{flat}/{num} {street}", ""
    return f"{num}{RNG.choice(['a', 'A', ''])} {street}", RNG.choice(["", " ", "-"])


# ---------------------------------------------------------------------------
# Free text — the primary cleaning target for phase 1
# ---------------------------------------------------------------------------

# A CSV cannot express "empty string" and "missing" differently unless the
# writer quotes one of them, and Postgres COPY draws exactly that line: an
# unquoted empty field becomes NULL, a quoted "" becomes a zero-length string.
# Real exports contain both, from different code paths in the same CRM, and
# staging has to collapse them (along with 'N/A', '-', '  ') to one thing.
# EMPTY_QUOTED is a sentinel swapped for a literal "" at write time — see
# write_csv — because Python's csv module will not quote an empty value.
EMPTY_QUOTED = "__EMPTY_QUOTED__"

PLACEHOLDERS = ["", "", "", EMPTY_QUOTED, EMPTY_QUOTED,
                "N/A", "n/a", "-", "none", "NONE", "NULL", "  ", "."]


def messy_text(s: str, placeholder_rate: float = 0.14) -> str:
    """Mangle a free-text field the way a decade of copy-paste does.

    DECISION: the mangling is layered, 0-3 effects per value, so no single
    cleaning rule fixes a whole column. That is deliberate — it forces the
    staging layer to compose cleaners rather than write one regex and declare
    victory. It is also why the *original* value is kept alongside the cleaned
    one downstream: 'tenant claims boiler serviced 3/4/24 - no cert' still
    means something after normalisation, but a Data Quality Analyst will be
    asked what the field literally said, and 'we normalised it away' is not an
    answer.
    """
    if maybe(placeholder_rate):
        return RNG.choice(PLACEHOLDERS)

    effects = RNG.sample(
        ["pad", "double_space", "tab", "newline", "moji", "upper",
         "entity", "html", "smart", "nbsp", "cr"],
        k=RNG.randint(0, 3),
    )
    if maybe(0.18):
        effects.append("moji")
    if "smart" in effects:
        s = s.replace("'", "\u2019").replace("--", "\u2014")
    if "moji" in effects:
        s = mojibake(s)
    if "upper" in effects:
        s = s.upper()
    if "entity" in effects:
        s = s.replace("&", "&amp;") + "&nbsp;"
    if "html" in effects:
        s = f"<p>{s}</p>" if maybe(0.5) else s.replace(". ", ".<br/>")
    if "nbsp" in effects:
        s = s.replace(" ", "\u00a0", 1)
    if "double_space" in effects:
        s = s.replace(" ", "  ", 2)
    if "tab" in effects:
        s = s.replace(" ", "\t", 1)
    if "newline" in effects:
        s = s.replace(". ", ".\n", 1)
    if "cr" in effects:
        s = s + "\r"
    if "pad" in effects:
        s = f"   {s}  "
    return s


LANDLORD_NOTES = [
    "Prefers contact by email only - do not phone.",
    "Owns 3 properties, invoice quarterly.",
    "Awaiting gas safety cert, chased 12/03/24.",
    "Tenant claims boiler serviced 3/4/24 - no cert on file.",
    "Overseas landlord - NRL scheme approved, ref NRL/8821.",
    "Deceased 2023 - estate handled by Kavanagh & Co solicitors.",
    "Do not call after 6pm. Wife handles all correspondence.",
    "Disputes management fee, see email thread 04/2024.",
    "New bank details supplied 11/01/2024 - verified by phone.",
    "Portfolio landlord – wants one consolidated statement, £450 fee.",
    "Refuses to sign new T&Cs. Escalated to branch manager.",
    "Address is care-of the son, mail returned twice.",
    "Café owner — daytime contact unreliable.",
    "Agreed 8% commission – legacy rate, not the standard 10%.",
]

PROPERTY_DESCRIPTIONS = [
    "A well presented mid terrace property in a sought after location.",
    "Spacious ground floor apartment with residents parking and gas heating.",
    "Recently refurbished throughout - new kitchen and bathroom 2023.",
    "Superb detached villa close to Queen’s University and the Botanic area.",
    "Two bedroom flat at £695 pcm, ideal first let. EPC rating D – no pets.",
    "Charming period townhouse retaining many original features.",
    "Modern apartment in the Gasworks development, secure entry & lift.",
    "Immaculate semi detached home with south facing rear garden.",
    "Student let - available from 1st September, 9 month term.",
    "Well maintained property, close to all local amenities & transport.",
]

TENANCY_COMMENTS = [
    "Deposit protected with TDS NI, ref 4821.",
    "Break clause at 6 months - either party, 2 months notice.",
    "Tenant in arrears from Feb 2024 - payment plan agreed.",
    "Pets permitted (one cat) by written agreement 03/2023.",
    "Joint tenancy - both parties liable for full rent.",
    "Guarantor in place – father’s details on record, £750 liability.",
    "Renewal declined by landlord, vacating end of term.",
    "Inventory completed at check-in, signed copy on file.",
    "Rent increased to £825 in 05/2024 following a section 4 notice.",
    "Ongoing damp complaint, surveyor attended 14/02/24.",
]

PAYMENT_REFS = [
    "RENT MAR24", "rent - 14 malone rd", "BACS//REF 8821", "Standing order",
    "rent payment", "MONTHLY RENT", "part payment - balance to follow",
    "deposit return", "arrears clearance", "s/o ref 40021",
    "rent \u2013 \u00a3750 pcm", "RENT \u2013 APR24",
]


# ---------------------------------------------------------------------------
# Table builders
# ---------------------------------------------------------------------------

def build_landlords() -> list[dict]:
    rows: list[dict] = []
    people: list[tuple[str, str]] = []
    for i in range(1, N_LANDLORDS + 1):
        first, last = RNG.choice(FIRST), RNG.choice(LAST)
        people.append((first, last))
        added = date(2015, 1, 1) + timedelta(days=RNG.randint(0, 3600))
        a1, a2 = fmt_address()
        rows.append({
            "LandlordRef": f"{AGENCY['code']}-{i:05d}",
            "Name": fmt_name(first, last),
            "Email": fmt_email(first, last),
            "Phone": fmt_phone(mobile=maybe(0.7)),
            "AddrLine1": a1,
            "AddrLine2": a2,
            "Town": RNG.choice(TOWNS),
            "Postcode": fmt_postcode(),
            "DateAdded": fmt_date(added),
            "Notes": messy_text(RNG.choice(LANDLORD_NOTES)),
            "Status": RNG.choice(["Active", "ACTIVE", "active", "Inactive",
                                  "INACTIVE", "", "Archived", "A"]),
        })

    # Same person, second record, different ref. Contact details differ only by
    # case and whitespace — invisible to a human, fatal to a naive GROUP BY.
    for j in range(N_DUPLICATE_LANDLORDS):
        src = rows[RNG.randrange(len(rows))]
        first, last = people[rows.index(src)]
        dup = dict(src)
        dup["LandlordRef"] = f"{AGENCY['code']}-9{j:04d}"
        dup["Name"] = fmt_name(first, last)
        dup["Email"] = f"  {src['Email'].strip().upper()}  " if src["Email"].strip() else ""
        dup["Notes"] = messy_text("Possible duplicate record - merge pending.")
        rows.append(dup)
    return rows


def build_properties(landlord_refs: list[str]) -> list[dict]:
    rows = []
    for i in range(1, N_PROPERTIES + 1):
        a1, a2 = fmt_address()
        rent = RNG.choice([525, 595, 650, 695, 750, 825, 900, 1100, 1250, 1450])
        rows.append({
            "PropRef": f"{AGENCY['code']}-P{i:05d}",
            "LandlordRef": RNG.choice(landlord_refs),
            "Addr1": a1,
            "Addr2": a2,
            "Town": RNG.choice(TOWNS),
            "PostCode": fmt_postcode(),
            "Beds": RNG.choice(["1", "2", "3", "4", "Studio", "2 bed", "", "3.0"]),
            "PropType": RNG.choice(["Terrace", "TERRACE", "Semi-Detached", "semi",
                                    "Apartment", "APT", "Detached", "Flat", ""]),
            "Description": messy_text(RNG.choice(PROPERTY_DESCRIPTIONS)),
            "MonthlyRent": fmt_money(rent),
            "DateListed": fmt_date(date(2018, 1, 1) + timedelta(days=RNG.randint(0, 2900))),
        })
    for k in range(N_ORPHAN_PROPERTIES):
        rows[RNG.randrange(len(rows))]["LandlordRef"] = f"{AGENCY['code']}-8{k:04d}"
    return rows


def build_tenancies(prop_refs: list[str]) -> list[dict]:
    rows = []
    for i in range(1, N_TENANCIES + 1):
        first, last = RNG.choice(FIRST), RNG.choice(LAST)
        start = date(2019, 1, 1) + timedelta(days=RNG.randint(0, 2200))
        ended = maybe(0.55)
        end = start + timedelta(days=RNG.choice([180, 365, 540, 730])) if ended else None
        rent = RNG.choice([525, 595, 650, 695, 750, 825, 900, 1100, 1250])
        rows.append({
            "TenancyRef": f"{AGENCY['code']}-T{i:05d}",
            "PropRef": RNG.choice(prop_refs),
            "TenantName": fmt_name(first, last),
            "TenantEmail": fmt_email(first, last),
            "TenantPhone": fmt_phone(mobile=True),
            "StartDate": fmt_date(start),
            "EndDate": fmt_date(end),
            "Rent": fmt_money(rent),
            "DepositHeld": fmt_money(rent * RNG.choice([1.0, 1.0, 1.5])),
            "Comments": messy_text(RNG.choice(TENANCY_COMMENTS)),
        })
    for k in range(N_ORPHAN_TENANCIES):
        rows[RNG.randrange(len(rows))]["PropRef"] = f"{AGENCY['code']}-P9{k:04d}"
    return rows


def build_payments(tenancy_refs: list[str]) -> list[dict]:
    rows = []
    for i in range(1, N_PAYMENTS + 1):
        paid = date(2021, 1, 1) + timedelta(days=RNG.randint(0, 1600))
        amt = RNG.choice([525, 595, 650, 695, 750, 825, 900, 1100, 1250])
        if maybe(0.04):
            amt = -RNG.choice([120, 250, 400])       # refund / deposit return
        elif maybe(0.05):
            amt = round(amt * RNG.uniform(0.2, 0.8), 2)  # part payment
        rows.append({
            "PaymentRef": f"{AGENCY['code']}-R{i:06d}",
            "TenancyRef": RNG.choice(tenancy_refs),
            "PaidOn": fmt_date(paid),
            "Amount": fmt_money(amt),
            "Method": RNG.choice(["BACS", "bacs", "Standing Order", "S/O",
                                  "Cash", "CASH", "Card", "cheque", ""]),
            "Reference": messy_text(RNG.choice(PAYMENT_REFS), placeholder_rate=0.22),
        })
    return rows


# ---------------------------------------------------------------------------

def write_csv(path: Path, rows: list[dict]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    # newline="" is required so csv writes embedded newlines correctly;
    # lineterminator="\n" keeps the file LF regardless of host OS, so the
    # checksum is stable across machines and the seed actually means something.
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    text = buf.getvalue().replace(EMPTY_QUOTED, '""')
    path.write_text(text, encoding="utf-8", newline="")
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(OUT_ROOT), help="output root directory")
    args = parser.parse_args()

    out_dir = Path(args.out) / AGENCY["slug"]

    landlords = build_landlords()
    properties = build_properties([r["LandlordRef"] for r in landlords])
    tenancies = build_tenancies([r["PropRef"] for r in properties])
    payments = build_payments([r["TenancyRef"] for r in tenancies])

    counts = {
        "landlords.csv": write_csv(out_dir / "landlords.csv", landlords),
        "properties.csv": write_csv(out_dir / "properties.csv", properties),
        "tenancies.csv": write_csv(out_dir / "tenancies.csv", tenancies),
        "payments.csv": write_csv(out_dir / "payments.csv", payments),
    }

    print(f"agency : {AGENCY['name']} ({AGENCY['slug']})")
    print(f"seed   : {SEED}")
    print(f"output : {out_dir}")
    for name, n in counts.items():
        print(f"  {name:<16} {n:>6,} rows")
    print(f"  {'TOTAL':<16} {sum(counts.values()):>6,} rows")


if __name__ == "__main__":
    main()
