# Stock

What CINDER holds, counted straight off the silos by CC, for a live
catalogue customers will see (Alex, 2026-10-03). Step 1 of 4 is built:
counting and reporting, and a stock list screen at each site. Picking
orders into a dock's intake, reserving stock for accepted orders, and
the customer-facing catalogue come next.

## Decided

- **No reference chest, no Stock Ticker.** What is in stock is the
  catalogue; CC reads it directly (`list()` on each inventory) and moves
  it directly (`pushItems`, later, for picking).
- **Stock per site, one stock for customers.** Each site's store
  computer counts its own silos; the base adds every site up. Customers
  never see which site holds what - the base does, to send an order to
  the right one.
- **No reserve held back** - production refills quickly.
- **Items with data of their own are separate entries:** two enchanted
  books with different enchantments, two potions, are two lines, each
  under its full name ("Enchanted Book (Mending)").
- **Cable inside a site, radio between sites.** The silos (and later the
  docks' intakes) are cabled to the site's store computer; the count goes
  to the base sealed, like everything else.

## Scale

Hundreds of thousands of items is a few thousand stacks. `list()` reads a
whole vault in one call however big it is, and the store reads up to 16
inventories in the same tick, so a full count is about a second. A sealed
message holds 8 KB, so the count goes to the base in pages
(`St.PAGE_BYTES`, about 80 kinds a page). Moving items later is one stack a
call, but many calls a tick: CC's own budget (5 ms a computer a tick) is
the limit, and it holds itself to it - a big pick takes more ticks, it
does not lag the server.

## A site's store computer

1. An advanced computer at the site, on the same cable network as the
   silos (a wired modem on each, cable to the computer; a full-block wired
   modem touches a vault without being part of it).
2. The first command with `role store`, then `label set store-chi` - the
   label is the site: `store-chi` counts for CHI.
3. On the base, a floppy in its drive: `seckey new store-chi`. On the store,
   the floppy in a drive: `seckey set disk`.
4. An ender modem on the store computer.
5. `store setup`: every inventory on the network, numbered. Answer with
   numbers and ranges for a fixed list, or **a word in their names**
   (`vault`) - then any vault cabled in later is counted with no setup.
   It then asks which monitor is the stock list.
6. `store count` to see what it finds; reboot, and `store` runs by itself.

`store status` shows the label, key, radio, screen and each inventory.

## The stock list screen

A monitor on the store's network (4x5 portrait at text scale 1 is 39x33):
every item the site holds, the most first, numbered, with the count on
the right; the total and the kinds along the top, and when it was
counted. UP and DOWN along the bottom scroll a screenful; the page number
between them goes back to the top, and so does the list by itself two
minutes after the last touch. It is counted again every 15 seconds, so
stock coming in shows within that.

## On the base

`ops stock` - every site added up, the most-held first; `ops stock all`,
`ops stock find <words>`, `ops stock sites` (each site, and when it last
counted). The base keeps each site's last full count in `stock.txt`; a
store sends a count every minute. Only a `store-<site>` key can count a
site: a depot's or a drone's key is refused.

Files: `store.lua`, `lib/store.lua` (counting, pages, the base's side),
`lib/storeui.lua` (the screen). Tests: `tools/run_store_test.py`, and the
base's side in `tools/run_ops_load_test.py`. Screens:
`tools/preview_nav.py --store`.
