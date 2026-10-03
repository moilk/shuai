//! Robustness: chunking invariance, no panics on arbitrary input, layout depth.

use proptest::prelude::*;
use shuai_tmux::layout::Layout;
use shuai_tmux::{ControlEvent, ControlParser};

fn fixtures() -> Vec<Vec<u8>> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures");
    let mut v: Vec<Vec<u8>> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| std::fs::read(e.unwrap().path()).unwrap())
        .collect();
    v.push(b"%begin 1 2 1\n%begin 1 2 1\n%output %1 x\n%end 1 3 1\n%end 1 2 1\n%output %1 \\303\\251\xff\xfe\n".to_vec());
    v.push(b"\x1bP1000p%begin 1 2 0\nhello\n%end 1 2 0\n%exit\n\x1b\\".to_vec());
    v
}

fn parse_chunks(data: &[u8], cuts: &[usize]) -> Vec<ControlEvent> {
    let mut p = ControlParser::new();
    let mut ev = vec![];
    let mut last = 0;
    let mut cuts: Vec<usize> = cuts.iter().map(|c| c % (data.len() + 1)).collect();
    cuts.sort();
    for c in cuts {
        ev.extend(p.push(&data[last..c]));
        last = c;
    }
    ev.extend(p.push(&data[last..]));
    ev
}

proptest! {
    #[test]
    fn chunking_is_invariant(idx in 0usize..8, cuts in prop::collection::vec(any::<usize>(), 0..20)) {
        let fx = fixtures();
        let data = &fx[idx % fx.len()];
        prop_assert_eq!(parse_chunks(data, &[]), parse_chunks(data, &cuts));
    }

    #[test]
    fn random_bytes_never_panic(data in prop::collection::vec(any::<u8>(), 0..2000),
                                cuts in prop::collection::vec(any::<usize>(), 0..10)) {
        let _ = parse_chunks(&data, &cuts);
    }

    #[test]
    fn random_protocol_lines_never_panic(lines in prop::collection::vec(
        (prop::sample::select(vec!["%output","%extended-output","%begin","%end","%error","%layout-change",
            "%subscription-changed","%session-renamed","%window-renamed","%client-session-changed","%exit","%pause",""]),
         "[ -~\\x80-\\xff]{0,40}"), 0..30)) {
        let mut s = String::new();
        for (k, rest) in lines { s.push_str(k); s.push(' '); s.push_str(&rest); s.push('\n'); }
        let _ = parse_chunks(s.as_bytes(), &[]);
    }

    #[test]
    fn layout_random_never_panics(s in "[0-9a-f,x{}\\[\\]]{0,80}") {
        let _ = Layout::parse(&s);
        let _ = Layout::parse(&format!("abcd,{s}"));
    }
}

#[test]
fn invalid_utf8_output_is_preserved_raw() {
    let mut p = ControlParser::new();
    let ev = p.push(b"%output %3 a\xffb\\303\n");
    assert_eq!(
        ev,
        vec![ControlEvent::Output {
            pane: shuai_tmux::PaneId(3),
            data: vec![b'a', 0xff, b'b', 0xc3]
        }]
    );
}

#[test]
fn begin_without_end_then_more_input_is_still_a_block() {
    let mut p = ControlParser::new();
    assert!(p.push(b"%begin 1 2 0\n%output %1 x\n%exit\n").is_empty());
    let ev = p.push(b"%end 1 2 0\n");
    assert!(matches!(&ev[0], ControlEvent::Reply(r) if r.lines.len() == 2));
}

#[test]
fn very_long_line_without_newline_is_bounded() {
    let mut p = ControlParser::new();
    let chunk = vec![b'a'; 1 << 20];
    for _ in 0..40 {
        let _ = p.push(&chunk);
    }
    // 40 MiB of newline-less data must not be retained unboundedly; the parser
    // resynchronises on the next newline.
    let ev = p.push(b"\n%sessions-changed\n");
    assert!(ev.contains(&ControlEvent::SessionsChanged));
}

#[test]
fn deeply_nested_layout_is_an_error_not_a_stack_overflow() {
    let n = 200_000;
    let s = format!("abcd,1x1,0,0{}", "{1x1,0,0".repeat(n));
    assert!(Layout::parse(&s).is_err());
    let s = format!("abcd,1x1,0,0{}", "[1x1,0,0".repeat(n));
    assert!(Layout::parse(&s).is_err());
}

#[test]
fn layout_shapes() {
    let l = Layout::parse("b25d,80x24,0,0,5").unwrap();
    assert_eq!(l.pane_ids(), vec![shuai_tmux::PaneId(5)]);
    let l = Layout::parse("abcd,80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],39x24,41,0,3}").unwrap();
    assert_eq!(l.pane_ids().len(), 3);
    for bad in ["", ",", "abcd", "abcd,", "abcd,80x24", "abcd,80x24,0,0", "abcd,80x24,0,0{", "abcd,80x24,0,0{}", "abcd,80x24,0,0,5x", "zzzz,1x1,0,0,1", "abcd,99999999999x1,0,0,1", "abcd,1x1,0,0{1x1,0,0,1]"] {
        assert!(Layout::parse(bad).is_err(), "{bad:?}");
    }
}
