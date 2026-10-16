import type { ReactNode } from "react";

interface LegalDocumentContentProps {
  content: string;
}

interface ContentBlock {
  type: "heading" | "paragraph";
  text: string;
}

function parseLegalContent(content: string): ContentBlock[] {
  const normalizedContent = content
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();

  if (!normalizedContent) {
    return [];
  }

  const paragraphs = normalizedContent
    .split(/\n\s*\n/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean);

  return paragraphs.map((text) => {
    const isNumberedHeading =
      /^\d+(?:\.\d+)*\.?\s+\S/.test(text) &&
      text.length < 180 &&
      !text.includes("\n");

    const isUppercaseHeading =
      text.length < 140 &&
      !text.includes("\n") &&
      /[A-ZÁÉÍÓÚÜÑ]/.test(text) &&
      text === text.toLocaleUpperCase("es-ES") &&
      /[A-ZÁÉÍÓÚÜÑ]/.test(text);

    if (isNumberedHeading || isUppercaseHeading) {
      return {
        type: "heading",
        text,
      };
    }

    return {
      type: "paragraph",
      text,
    };
  });
}

export default function LegalDocumentContent({
  content,
}: LegalDocumentContentProps) {
  const blocks = parseLegalContent(content);

  return (
    <div className="space-y-5">
      {blocks.map((block, index): ReactNode => {
        if (block.type === "heading") {
          return (
            <h2
              key={`${index}-${block.text}`}
              className="text-lg md:text-xl font-semibold text-[#1E3A8A] leading-7 pt-3"
            >
              {block.text}
            </h2>
          );
        }

        return (
          <p
            key={`${index}-${block.text}`}
            className="text-gray-600 leading-8 whitespace-pre-line"
          >
            {block.text}
          </p>
        );
      })}
    </div>
  );
}