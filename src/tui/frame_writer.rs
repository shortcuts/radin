use std::cell::RefCell;
use std::io::{BufWriter, Result, Write};
use std::rc::Rc;

const CAPACITY: usize = 64 * 1024;

/// Buffers a whole frame. `flush` does nothing because ratatui flushes inside `draw`,
/// before the `?2026l` mark; `send` on a clone is the one real flush.
pub struct FrameWriter<W: Write> {
    buf: Rc<RefCell<BufWriter<W>>>,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> Self {
        Self {
            buf: Rc::new(RefCell::new(BufWriter::with_capacity(CAPACITY, inner))),
        }
    }

    pub fn handle(&self) -> Self {
        Self {
            buf: Rc::clone(&self.buf),
        }
    }

    pub fn send(&self) -> Result<()> {
        self.buf.borrow_mut().flush()
    }
}

impl<W: Write> Write for FrameWriter<W> {
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        self.buf.borrow_mut().write(buf)
    }

    fn flush(&mut self) -> Result<()> {
        Ok(())
    }
}
