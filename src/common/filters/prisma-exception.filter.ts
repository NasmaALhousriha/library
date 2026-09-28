import { ArgumentsHost, Catch, ExceptionFilter, HttpStatus, Logger } from '@nestjs/common';
import type { Response } from 'express';
import { Prisma } from '../../generated/prisma/client.js';

const SQL_FUNCTION_ERRORS: Record<string, HttpStatus> = {
  P0010: HttpStatus.NOT_FOUND, // Book not found
  P0012: HttpStatus.CONFLICT, // Copies available, borrow directly
  P0013: HttpStatus.CONFLICT, // Already in the queue
  P0014: HttpStatus.NOT_FOUND, // Borrowing not found or already returned
  P0015: HttpStatus.CONFLICT, // Already borrowed this book
  P0016: HttpStatus.NOT_FOUND, // Reservation not found or expired
  P0017: HttpStatus.NOT_FOUND, // Queue entry not found
  P0018: HttpStatus.CONFLICT, // Queue entry can no longer be cancelled
};

type PrismaError =
  | Prisma.PrismaClientKnownRequestError
  | Prisma.PrismaClientUnknownRequestError;

type DriverCause = { originalCode?: string; originalMessage?: string };

@Catch(Prisma.PrismaClientKnownRequestError, Prisma.PrismaClientUnknownRequestError)
export class PrismaExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(PrismaExceptionFilter.name);

  catch(exception: PrismaError, host: ArgumentsHost) {
    const response = host.switchToHttp().getResponse<Response>();
    const { status, message } = this.toHttp(exception);

    if (status === HttpStatus.INTERNAL_SERVER_ERROR) {
      this.logger.error(exception.message, exception.stack);
    }

    response.status(status).json({ statusCode: status, message });
  }

  private toHttp(exception: PrismaError): { status: HttpStatus; message: string } {
    const meta = (exception as { meta?: Record<string, unknown> }).meta;
    const cause = (meta?.driverAdapterError as { cause?: DriverCause } | undefined)?.cause;
    const pgCode = cause?.originalCode;

    if (pgCode && SQL_FUNCTION_ERRORS[pgCode]) {
      return { status: SQL_FUNCTION_ERRORS[pgCode], message: cause?.originalMessage ?? 'Request failed' };
    }
    if (pgCode === '23505') return { status: HttpStatus.CONFLICT, message: 'Duplicate entry' };
    if (pgCode === '23503') return { status: HttpStatus.BAD_REQUEST, message: 'Related record does not exist' };
    if (pgCode === '22P02') return { status: HttpStatus.BAD_REQUEST, message: 'Invalid data format' };

    if (exception instanceof Prisma.PrismaClientKnownRequestError) {
      if (exception.code === 'P2002') return { status: HttpStatus.CONFLICT, message: 'Duplicate entry' };
      if (exception.code === 'P2025') return { status: HttpStatus.NOT_FOUND, message: 'Record not found' };
    }

    return { status: HttpStatus.INTERNAL_SERVER_ERROR, message: 'Internal server error' };
  }
}
