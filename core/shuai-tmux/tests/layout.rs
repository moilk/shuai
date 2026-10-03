use shuai_tmux::layout::checksum;
use shuai_tmux::*;

fn leaf(w: u32, h: u32, x: u32, y: u32, id: u32) -> LayoutNode {
    LayoutNode {
        width: w,
        height: h,
        x,
        y,
        kind: LayoutKind::Pane(PaneId(id)),
    }
}

#[test]
fn single_pane() {
    let l = Layout::parse("a87d,100x30,0,0,0").unwrap();
    assert_eq!(l.checksum, "a87d");
    assert_eq!(l.root, leaf(100, 30, 0, 0, 0));
    assert!(l.checksum_ok());
    assert_eq!(l.pane_ids(), [PaneId(0)]);
}

#[test]
fn left_right_split_from_real_tmux() {
    let l = Layout::parse("f926,120x40,0,0{60x40,0,0,2,59x40,61,0,3}").unwrap();
    assert!(l.checksum_ok());
    assert_eq!(
        l.root,
        LayoutNode {
            width: 120,
            height: 40,
            x: 0,
            y: 0,
            kind: LayoutKind::LeftRight(vec![leaf(60, 40, 0, 0, 2), leaf(59, 40, 61, 0, 3)]),
        }
    );
}

#[test]
fn nested_from_real_tmux() {
    let raw = "bd79,120x40,0,0{60x40,0,0[60x20,0,0,0,60x19,0,21,4],59x40,61,0[59x20,61,0,1,59x19,61,21{29x19,61,21,2,29x19,91,21,3}]}";
    let l = Layout::parse(raw).unwrap();
    assert!(l.checksum_ok());
    assert_eq!(
        l.pane_ids(),
        [PaneId(0), PaneId(4), PaneId(1), PaneId(2), PaneId(3)]
    );
    let LayoutKind::LeftRight(cols) = &l.root.kind else {
        panic!()
    };
    assert_eq!(cols.len(), 2);
    let LayoutKind::TopBottom(rows) = &cols[1].kind else {
        panic!()
    };
    assert_eq!(rows.len(), 2);
    assert!(matches!(&rows[1].kind, LayoutKind::LeftRight(c) if c.len() == 2));
}

#[test]
fn bad_checksum_is_reported_not_fatal() {
    let l = Layout::parse("0000,100x30,0,0,0").unwrap();
    assert!(!l.checksum_ok());
}

#[test]
fn checksum_function() {
    assert_eq!(checksum("100x30,0,0,0"), 0xa87d);
    assert_eq!(checksum("120x40,0,0{60x40,0,0,2,59x40,61,0,3}"), 0xf926);
}

#[test]
fn malformed() {
    for bad in [
        "",
        "a87d",
        "a87d,100x30",
        "a87d,100x30,0,0",
        "a87d,axb,0,0,0",
        "a87d,100x30,0,0{60x40,0,0,2",
        "a87d,100x30,0,0,0,trailing",
        "zzzz,100x30,0,0,0",
        "a87d,100x30,0,0{}",
    ] {
        assert!(Layout::parse(bad).is_err(), "{bad:?}");
    }
}
